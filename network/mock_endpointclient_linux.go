package network

import (
	"errors"
	"fmt"
)

var errMockEpClient = errors.New("MockEndpointClient Error")

func newErrorMockEndpointClient(errStr string) error {
	return fmt.Errorf("%w : %s", errMockEpClient, errStr)
}

type MockEndpointClient struct {
	endpoints   map[string]bool
	returnError bool
}

func NewMockEndpointClient(returnError bool) *MockEndpointClient {
	client := &MockEndpointClient{
		endpoints:   make(map[string]bool),
		returnError: returnError,
	}

	return client
}

func (client *MockEndpointClient) AddEndpoints(epInfo *EndpointInfo) error {
	if ok, _ := client.endpoints[epInfo.Id]; ok {
		return newErrorMockEndpointClient("Endpoint already exists")
	}

	client.endpoints[epInfo.Id] = true

	if client.returnError {
		return newErrorMockEndpointClient("AddEndpoints failed")
	}

	return nil
}

func (client *MockEndpointClient) AddEndpointRules(epInfo *EndpointInfo) error {
	return nil
}

func (client *MockEndpointClient) DeleteEndpointRules(ep *endpoint) {

}

func (client *MockEndpointClient) MoveEndpointsToContainerNS(epInfo *EndpointInfo, nsID uintptr) error {
	return nil
}

func (client *MockEndpointClient) SetupContainerInterfaces(epInfo *EndpointInfo) error {
	return nil
}

func (client *MockEndpointClient) ConfigureContainerInterfacesAndRoutes(epInfo *EndpointInfo) error {
	return nil
}

func (client *MockEndpointClient) setupIPV6Routes() error {
	return nil
}

func (client *MockEndpointClient) setIPV6NeighEntry() error {
	return nil
}

func (client *MockEndpointClient) DeleteEndpoints(ep *endpoint, _ bool) error {
	delete(client.endpoints, ep.Id)
	return nil
}
