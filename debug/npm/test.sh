kubectl get svc -n toolbox -o jsonpath="{range .items[*]}{.metadata.name} {.spec.type} {.spec.externalTrafficPolicy} {.spec.selector} {'\n'}{end}" > tmp-svc2.txt
while read -r svcInfo; do
    echo $svcInfo
done < tmp-svc2.txt