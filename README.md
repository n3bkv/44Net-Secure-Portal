# 44Net-Secure-Portal
This project builds a secure web portal on a Raspberry Pi that’s reachable from the 44Net / public internet.   It uses Traefik for reverse-proxy and automatic TLS via Let’s Encrypt, and Authelia to enforce login before forwarding traffic to a private backend (like a Node-RED dashboard on `192.168.x.x`).
