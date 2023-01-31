FROM mcr.microsoft.com/windows/servercore:ltsc2022 as Builder

# Run as admin
USER ContainerAdministrator

WORKDIR /azure-container-networking/cni/network/plugin
COPY azure-vnet.exe .

## build azure cni for windows
WORKDIR /azure-container-networking/cni
COPY cni/azure-windows.conflist .

WORKDIR /azure-container-networking
COPY cni/scripts/installcni.ps1 .

ENTRYPOINT ["powershell.exe", ".\\installcni.ps1"]