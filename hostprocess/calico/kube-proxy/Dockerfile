ARG WINDOWS_VERSION="ltsc2022"
FROM mcr.microsoft.com/windows/nanoserver:${WINDOWS_VERSION}

ENV PATH="C:\Windows\system32;C:\Windows;C:\WINDOWS\System32\WindowsPowerShell\v1.0\;"

ADD start.ps1 /kube-proxy/start.ps1
ADD kube-proxy.exe /kube-proxy/kube-proxy.exe
ADD hns.psm1 /kube-proxy/hns.psm1

ENTRYPOINT ["powershell.exe"]
