VERBOSE=false

echo "This script will help determine if your cluster is affected by NPM's k8s 1.27+ behavior change."
echo "Please additionally refer to the TSG to verify if your cluster is affected by NPM's k8s 1.27+ behavior change."
echo "TSG: https://github.com/Azure/azure-container-networking/wiki/TSG:-Azure-NPM-Behavior-Change-for-Kubernetes-1.27"
echo
echo "REQUIREMENT: kubectl version >= 1.23.16"
echo "There will be FALSE NEGATIVES if the kubectl requirement is NOT met due to issues with jsonpath. Please upgrade kubectl to >= 1.23.16."
echo
echo "NOTE: This script has only been tested on a cluster with k8s v1.24.9. Please use discretion when reading output from this script."
echo "See https://kubernetes.io/releases/download/#binaries for more information."
echo
if [[ $1 != "-y" ]]; then
    echo "Please read the above information and run the script again with the -y flag to continue."
    exit 1
fi
sleep 5s

echo "BEGINNING SCRIPT..."
echo "determining if NPM's k8s 1.27+ behavior change will affect your cluster and if action is needed..."

kubectl get svc --all-namespaces -o jsonpath="{range .items[*]}{.metadata.namespace} {.metadata.name} {.spec.type} {.spec.externalTrafficPolicy} {.spec.selector} {'\n'}{end}" | grep "LoadBalancer\|NodePort" > tmp-svc.txt
if [[ `cat tmp-svc.txt | wc -l` == 0 ]]; then
    echo "No services of type LoadBalancer or NodePort found"
    echo "NPM's k8s 1.27+ behavior change will not affect your cluster as is. No action is needed"
    rm tmp-svc.txt
    exit 0
fi

echo "Found services of type LoadBalancer and/or NodePort in the following namespaces: `cat tmp-svc.txt | awk '{print $1}' | sort | uniq`"
echo "Determining if any of these services are affected by NPM's k8s 1.27+ behavior change..."
foundPotentialImpact=false
prev_ns=""
while read -r svc; do
    svc_ns=`echo $svc | awk '{print $1}'`
    svc_name=`echo $svc | awk '{print $2}'`
    svc_type=`echo $svc | awk '{print $3}'`
    # will be non-empty because we only get services of type LoadBalancer or NodePort
    # from testing, this field will always be non-empty, even if not provided in the yaml file applied (which results in the value being Cluster)
    svc_etc=`echo $svc | awk '{print $4}'`
    # follows the format
    # 1. {"hello":"goodbye","ho":"hey"}
    # 2. "" (empty if the service has no selector)
    svc_selector=`echo $svc | awk '{print $5}'`

    if [[ $svc_ns != $prev_ns  ]]; then
        echo "checking namespace $svc_ns..."
        prev_ns=$svc_ns
        # from testing, PolicyType can have values ["Ingress"] or ["Egress"] or ["Ingress", "Egress"] or ["Egress", "Ingress"]
        # PolicyType is always populated for NetworkPolicies, even if not provided in the yaml file applied (which results in the value being ["Ingress"])
        kubectl get networkpolicy -n $svc_ns -o jsonpath="{range .items[*]}{.metadata.name} {.spec.podSelector} {.spec.policyTypes} {'\n'}{end}" | grep '\["Ingress"\|"Ingress"\]' > tmp-netpol.txt
        netpolCount=`cat tmp-netpol.txt | wc -l`
        if [[ $netpolCount == 0 ]]; then
            echo "INFO: unable to find NetworkPolicies with ingress rules in namespace $svc_ns. If this is true, no action is needed for this namespace."
        fi
    fi
    if [[ $netpolCount == 0 ]]; then
        continue
    fi

    if [[ $VERBOSE == true ]]; then
        echo "checking service $svc..."
    fi

    if [[ $svc_selector == "" ]]; then
        foundPotentialImpact=true
        if [[ $svc_etc == "Cluster" ]]; then
            echo "WARNING: due to an empty Service selector, unable to validate impact of NPM's k8s 1.27+ behavior change on the following service. Please follow the TSG to ensure for k8s 1.27+ that the Service's Endpoints have ingress allowed. Service: $svc_name. Namespace: $svc_ns"
        else
            echo "INFO: technically no action required for the following $svc_type service since it has externalTrafficPolicy=Local, although changing to externalTrafficPolicy=Cluster could potentially require action. Due to an empty Service selector, unable to provide further insights. Service: $svc_name. Namespace: $svc_ns"
        fi
        echo
        continue
    fi

    foundMatchExpressions=false
    foundOverlap=false
    while read -r np; do
        if [[ $VERBOSE == true ]]; then
            echo "Checking networkpolicy $np..."
        fi
        np_name=`echo $np | awk '{print $1}'`
        # from testing, this field will always be non-empty, even if not provided in the yaml file applied (which results in the value being {})
        # follows the format:
        # 1. {"matchExpressions":[{"key":"app","operator":"NotIn","values":["toolbox"]},{"key":"app","operator":"Exists"}],"matchLabels":{"hey":"ho"}}
        # 2. {"matchLabels":{"app":"konnectivity-agent"}}
        # 3. {}
        np_selector=`echo $np | awk '{print $2}'`

        if [[ $np_selector == "{}" ]]; then
            foundOverlap=true
        else
            echo $np_selector | grep -q "matchExpressions"
            if [[ $? == 0 ]]; then
                foundMatchExpressions=true
                # instead of checking every scenario with matchExpressions (which could be buggy), defer to human evaluation for these NetworkPolicies, unless an overlap is found
                continue
            fi

            # at this point, have matchLabels and don't have matchExpressions
            # this format: {"matchLabels":{"app":"konnectivity-agent"},{"debug":"true"}}
            for np_key_value in `echo $np_selector | sed 's/{"matchLabels"://g' | tr ',' ' ' | tr '{' ' ' | tr '}' ' ' | xargs echo`; do
                # guaranteed to enter loop at least once by check above (see the WARNING)
                for svc_key_value in `echo $svc_selector | tr ',' ' ' | tr '{' ' ' | tr '}' ' ' | xargs echo`; do
                    if [[ $svc_key_value == $np_key_value ]]; then
                        foundOverlap=true
                        if [[ $VERBOSE == true ]]; then
                            echo "found overlap for key-value pair $svc_key_value"
                        fi
                        break
                    fi
                done
                if [[ $foundOverlap == true ]]; then
                    break
                fi
            done
        fi

        if [[ $foundOverlap == true ]]; then
            foundPotentialImpact=true
            if [[ $svc_etc == "Cluster" ]]; then
                echo "ACTION REQUIRED for k8s 1.27+: ensure that client IPs are allowed to the target port of the following $svc_type service with externalTrafficPolicy=Cluster. At least one NetworkPolicy targets ingress to the Service's backend Pods. There may be more relevant NetworkPolicies. Service: $svc_name. Namespace: $svc_ns. Given NetworkPolicy: $np_name. NetworkPolicy Selector: $np_selector. Service Selector: $svc_selector"
            else
                echo "INFO: technically no action required for the following $svc_type service since it has externalTrafficPolicy=Local, although changing to externalTrafficPolicy=Cluster would require action. At least one NetworkPolicy targets ingress to the Service's backend Pods. Service: $svc_name. Namespace: $svc_ns. Given NetworkPolicy: $np_name. NetworkPolicy Selector: $np_selector. Service Selector: $svc_selector"
            fi
            echo
            break
        fi
    done < tmp-netpol.txt

    if [[ $foundMatchExpressions == true && $foundOverlap == false ]]; then
        foundPotentialImpact=true
        if [[ $svc_etc == "Cluster" ]]; then
            echo "WARNING: due to the use of matchExpressions in a NetworkPolicy, unable to fully validate impact of NPM's k8s 1.27+ behavior change on the following service. Please follow the TSG to ensure for k8s 1.27+ that the Service's Endpoints have ingress allowed. Service: $svc_name. Namespace: $svc_ns"
        else
            echo "INFO: technically no action required for the following $svc_type service since it has externalTrafficPolicy=Local, although changing to externalTrafficPolicy=Cluster could potentially require action. Due to the use of matchExpressions in a NetworkPolicy, unable to provide further insights. Service: $svc_name. Namespace: $svc_ns"
        fi
        echo
    fi
done < tmp-svc.txt

echo "FINISHED SCRIPT"
if [[ $foundPotentialImpact == true ]]; then
    echo "Above services may require action for NPM's k8s 1.27+ behavior change."
else
    echo "No services found that are affected by NPM's k8s 1.27+ behavior change. No action is needed."
fi
echo "Please refer to the TSG for more information. https://github.com/Azure/azure-container-networking/wiki/TSG:-Azure-NPM-Behavior-Change-for-Kubernetes-1.27"

rm tmp-svc.txt
rm tmp-netpol.txt
