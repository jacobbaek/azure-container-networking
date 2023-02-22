FROM mcr.microsoft.com/windows/servercore:ltsc2019 as Builder

# Run as admin
USER ContainerAdministrator

SHELL ["powershell", "-command"]

ARG VERSION

RUN Write-Host $($env:VERSION)

## build azure cni for windows
WORKDIR /azure-container-networking/cni/network/plugin/
RUN go build -a -o azure-vnet.exe -ldflags "-X main.version=%VERSION%"



