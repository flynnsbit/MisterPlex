FROM nginx:stable-alpine

RUN apk add --no-cache curl iptables

COPY default.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /usr/local/bin/plex-cors-entrypoint

ENTRYPOINT ["/usr/local/bin/plex-cors-entrypoint"]
