FROM mcr.microsoft.com/windows/servercore:ltsc2022 as Builder

USER ContainerAdministrator

WORKDIR /azure-container-networking/cni/network/plugin
COPY azure-vnet.exe .

WORKDIR /azure-container-networking
COPY cni/scripts/update-cni.ps1 .

ENTRYPOINT ["powershell.exe", ".\\update-cni.ps1"]