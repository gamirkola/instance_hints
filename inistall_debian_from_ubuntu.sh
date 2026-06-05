sudo -i

apt update
apt install -y curl wget ca-certificates

curl -fLO https://raw.githubusercontent.com/bohanyang/debi/master/debi.sh
chmod +x debi.sh

./debi.sh \
  --disk /dev/sda \
  --cloudflare \
  --user debian \
