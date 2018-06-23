FROM nginx:1.15.0-alpine
MAINTAINER Keith Moss <keithamoss@gmail.com>

RUN rm -rf /etc/nginx
COPY nginx /etc/nginx

# EXPOSE 80 443

# ENTRYPOINT ["/app/docker-entrypoint.sh"]

CMD ["nginx", "-g", "daemon off;"]
