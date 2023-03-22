Write-Host $env:CONTAINER_SANDBOX_MOUNT_POINT

$sourceCNI = $env:CONTAINER_SANDBOX_MOUNT_POINT + "\azure-container-networking\cni\network\plugin\azure-vnet.exe"

Rename-Item -Path "C:\k\azurecni\bin\azure-vnet.exe" -NewName "azure-vnet-old.exe"

Copy-Item $sourceCNI -Destination "C:\k\azurecni\bin"