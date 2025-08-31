#Notes
Install local managed tunnel as per guide: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/local-management/create-local-tunnel/

```
cloudflared tunnel login
cloudflared tunnel create cluster1
cloudflared tunnel route ip add 10.0.0.0/8 cluster1
```
Get credentials file and add to bitwarden secret eg: `cat /home/gary/.cloudflared/0d9b5c66-1a46-4af3-ab1d-427b31f9999a.json`

