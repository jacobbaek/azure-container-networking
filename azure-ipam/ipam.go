package main

import (
	"context"
	"encoding/json"
	"io"
	"net"

	"github.com/Azure/azure-container-networking/azure-ipam/internal/buildinfo"
	"github.com/Azure/azure-container-networking/azure-ipam/ipconfig"
	"github.com/Azure/azure-container-networking/cns"
	cnscli "github.com/Azure/azure-container-networking/cns/client"
	cniSkel "github.com/containernetworking/cni/pkg/skel"
	cniTypes "github.com/containernetworking/cni/pkg/types"
	types100 "github.com/containernetworking/cni/pkg/types/100"
	"github.com/pkg/errors"
	"go.uber.org/zap"
)

// IPAMPlugin is the struct for the delegated azure-ipam plugin
// https://www.cni.dev/docs/spec/#section-4-plugin-delegation
type IPAMPlugin struct {
	Name      string
	Version   string
	Options   map[string]interface{}
	logger    *zap.Logger
	cnsClient cnsClient
	out       io.Writer // indicate the output channel for the plugin
}

type cnsClient interface {
	RequestIPAddress(context.Context, cns.IPConfigRequest) (*cns.IPConfigResponse, error)
	RequestIPs(context.Context, cns.IPConfigRequest) (*cns.IPConfigsResponse, error)
	ReleaseIPs(context.Context, cns.IPConfigRequest) error
}

// NewPlugin constructs a new IPAM plugin instance with given logger and CNS client
func NewPlugin(logger *zap.Logger, c cnsClient, out io.Writer) (*IPAMPlugin, error) {
	plugin := &IPAMPlugin{
		Name:      pluginName,
		Version:   buildinfo.Version,
		logger:    logger,
		out:       out,
		cnsClient: c,
	}
	return plugin, nil
}

//
// CNI implementation
// https://github.com/containernetworking/cni/blob/master/SPEC.md
//

// CmdAdd handles CNI add commands.
func (p *IPAMPlugin) CmdAdd(args *cniSkel.CmdArgs) error {
	p.logger.Info("ADD called", zap.Any("args", args))

	// Parsing network conf
	nwCfg, err := parseNetConf(args.StdinData)
	if err != nil {
		p.logger.Error("Failed to parse CNI network config from stdin", zap.Error(err), zap.Any("argStdinData", args.StdinData))
		return cniTypes.NewError(cniTypes.ErrDecodingFailure, err.Error(), "failed to parse CNI network config from stdin")
	}
	p.logger.Debug("Parsed network config", zap.Any("netconf", nwCfg))

	// Create ip config request from args
	req, err := ipconfig.CreateIPConfigReq(args)
	if err != nil {
		p.logger.Error("Failed to create CNS IP config request", zap.Error(err))
		return cniTypes.NewError(ErrCreateIPConfigRequest, err.Error(), "failed to create CNS IP config request")
	}
	p.logger.Debug("Created CNS IP config request", zap.Any("request", req))

	p.logger.Debug("Making request to CNS")
	// if this fails, the caller plugin should execute again with cmdDel before returning error.
	// https://www.cni.dev/docs/spec/#delegated-plugin-execution-procedure
	resp, err := p.cnsClient.RequestIPs(context.TODO(), req)
	if err != nil {
		// if we fail a request with a 404 error try using the old API
		if errors.Is(err, cnscli.ErrAPINotFound) {
			p.logger.Error("Failed to request IPs using RequestIPs from CNS, going to try RequestIPAddress", zap.Error(err), zap.Any("request", req))
			res, err := p.cnsClient.RequestIPAddress(context.TODO(), req)
			
			// if the old API fails as well then we just return the error
			if err != nil {
				p.logger.Error("Failed to request IP address from CNS using RequestIPAddress", zap.Error(err), zap.Any("request", req))
				return cniTypes.NewError(ErrRequestIPConfigFromCNS, err.Error(), "failed to request IP address from CNS")
			}
			// takes values from the IPConfigResponse struct and puts them in a IPConfigsResponse struct
			resp = &cns.IPConfigsResponse{
				Response: res.Response,
				PodIPInfo: []cns.PodIpInfo{
					res.PodIpInfo,
				},
			}
		} else {
			p.logger.Error("Failed to request IP address from CNS", zap.Error(err), zap.Any("request", req))
			return cniTypes.NewError(ErrRequestIPConfigFromCNS, err.Error(), "failed to request IP address from CNS")
		}
	}
	p.logger.Debug("Received CNS IP config response", zap.Any("response", resp))

	// Get Pod IP and gateway IP from ip config response
	podIPNet, err := ipconfig.ProcessIPConfigResp(resp)
	if err != nil {
		p.logger.Error("Failed to interpret CNS IPConfigResponse", zap.Error(err), zap.Any("response", resp))
		return cniTypes.NewError(ErrProcessIPConfigResponse, err.Error(), "failed to interpret CNS IPConfigResponse")
	}

	cniResult := &types100.Result{}
	cniResult.IPs = make([]*types100.IPConfig, len(*podIPNet))
	for i, ipNet := range *podIPNet {
		p.logger.Debug("Parsed pod IP", zap.String("podIPNet", ipNet.String()))
		ipConfig := &types100.IPConfig{}
		if ipNet.Addr().Is4() { 
			ipConfig.Address = net.IPNet{
				IP:   net.ParseIP(ipNet.Addr().String()),
				Mask: net.CIDRMask(ipNet.Bits(), 32), // nolint
			}
		} else {
			ipConfig.Address = net.IPNet{
				IP:   net.ParseIP(ipNet.Addr().String()),
				Mask: net.CIDRMask(ipNet.Bits(), 128), // nolint
			}
		}
		cniResult.IPs[i] = ipConfig
	}

	// Get versioned result
	versionedCniResult, err := cniResult.GetAsVersion(nwCfg.CNIVersion)
	if err != nil {
		p.logger.Error("Failed to interpret CNI result with netconf CNI version", zap.Error(err), zap.Any("cniVersion", nwCfg.CNIVersion))
		return cniTypes.NewError(cniTypes.ErrIncompatibleCNIVersion, err.Error(), "failed to interpret CNI result with netconf CNI version")
	}

	p.logger.Info("ADD success", zap.Any("result", versionedCniResult))

	// Write result to output channel
	err = versionedCniResult.PrintTo(p.out)
	if err != nil {
		p.logger.Error("Failed to print CNI result to output channel", zap.Error(err), zap.Any("result", versionedCniResult))
		return cniTypes.NewError(cniTypes.ErrIOFailure, err.Error(), "failed to print CNI result to output channel")
	}

	return nil
}

// CmdDel handles CNI delete commands.
func (p *IPAMPlugin) CmdDel(args *cniSkel.CmdArgs) error {
	p.logger.Info("DEL called", zap.Any("args", args))

	// Create ip config request from args
	req, err := ipconfig.CreateIPConfigReq(args)
	if err != nil {
		p.logger.Error("Failed to create CNS IP config request", zap.Error(err))
		return cniTypes.NewError(cniTypes.ErrTryAgainLater, err.Error(), "failed to create CNS IP config request")
	}
	p.logger.Debug("Created CNS IP config request", zap.Any("request", req))

	p.logger.Debug("Making request to CNS")
	// cnsClient enforces it own timeout
	if err := p.cnsClient.ReleaseIPs(context.TODO(), req); err != nil {
		p.logger.Error("Failed to release IP address from CNS", zap.Error(err), zap.Any("request", req))
		return cniTypes.NewError(cniTypes.ErrTryAgainLater, err.Error(), "failed to release IP address from CNS")
	}

	p.logger.Info("DEL success")

	return nil
}

// CmdCheck handles CNI check command - not implemented
func (p *IPAMPlugin) CmdCheck(args *cniSkel.CmdArgs) error {
	p.logger.Info("CHECK called")
	return nil
}

// Parse network config from given byte array
func parseNetConf(b []byte) (*cniTypes.NetConf, error) {
	netConf := &cniTypes.NetConf{}
	err := json.Unmarshal(b, netConf)
	if err != nil {
		return nil, errors.Wrapf(err, "failed to unmarshal net conf")
	}

	if netConf.CNIVersion == "" {
		netConf.CNIVersion = "0.2.0" // default CNI version
	}

	return netConf, nil
}
