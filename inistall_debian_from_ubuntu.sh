sudo -i

apt update
apt install -y curl wget ca-certificates

curl -fLO https://raw.githubusercontent.com/bohanyang/debi/master/debi.sh
chmod +x debi.sh

./debi.sh \
  --version 13 \
  --cloudflare \
  --static-ipv4 \
  --cloud-kernel \
  --firmware \
  --efi \
  --user debian \
  --timezone Europe/Rome \
  --network-console \
  --install 'curl wget vim htop sudo openssh-server ca-certificates gnupg'