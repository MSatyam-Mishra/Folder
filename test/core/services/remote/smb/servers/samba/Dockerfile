FROM alpine:3.20
RUN apk add --no-cache samba samba-common-tools
COPY smb.conf /etc/samba/smb.conf
RUN adduser -D -H tester && (echo 'Secret123'; echo 'Secret123') | smbpasswd -a -s tester \
 && mkdir -p /share/public /share/data /share/secret && chown tester /share/* && chmod 777 /share/*
EXPOSE 445
CMD ["smbd", "--foreground", "--no-process-group", "--debug-stdout"]
