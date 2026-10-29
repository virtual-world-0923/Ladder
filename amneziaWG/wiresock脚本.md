

wiresock 里的脚本

wiresock 官网 https://wiresock.net/



curl -fLO https://raw.githubusercontent.com/wiresock/awg-server-tools/main/amneziawg-install.sh
chmod +x amneziawg-install.sh
sudo ./amneziawg-install.sh



可选：添加网络面板

curl -fLO https://raw.githubusercontent.com/wiresock/awg-server-tools/main/amneziawg-web.sh
chmod +x amneziawg-web.sh
sudo ./amneziawg-web.sh install --install-rust



面板监听 127.0.0.1:8080. 从您的计算机打开一个 SSH 隧道，然后访问 http://localhost:8080:

ssh -L 8080:127.0.0.1:8080 user@your-server
