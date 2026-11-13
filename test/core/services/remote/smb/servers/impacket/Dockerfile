FROM python:3.12-slim
RUN pip install --no-cache-dir impacket==0.13.1
RUN mkdir -p /share && chmod 777 /share
WORKDIR /work
EXPOSE 4455
CMD ["sh", "-c", "smbserver.py -smb2support -port 4455 -username tester -password Secret123 TEST /share"]
