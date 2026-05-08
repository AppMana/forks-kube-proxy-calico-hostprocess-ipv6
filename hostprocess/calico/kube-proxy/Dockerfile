ARG WINDOWS_VERSION="ltsc2022"
FROM mcr.microsoft.com/powershell:lts-nanoserver-${WINDOWS_VERSION}

ADD start.ps1 /kube-proxy/start.ps1
ADD kube-proxy.exe /kube-proxy/kube-proxy.exe
ADD hns.psm1 /kube-proxy/hns.psm1

# HostProcess containers run on the host, not in the image.
# Use the host's powershell.exe (not the image's pwsh.exe) as entrypoint.
# The image still includes pwsh for ctr-run debugging.
ENTRYPOINT ["powershell.exe"]
