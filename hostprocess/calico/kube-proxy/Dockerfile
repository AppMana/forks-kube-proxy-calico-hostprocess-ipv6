ARG WINDOWS_VERSION="ltsc2022"
FROM mcr.microsoft.com/powershell:lts-nanoserver-${WINDOWS_VERSION}

ADD start.ps1 /kube-proxy/start.ps1
ADD kube-proxy.exe /kube-proxy/kube-proxy.exe
ADD hns.psm1 /kube-proxy/hns.psm1

ENTRYPOINT ["pwsh.exe"]
