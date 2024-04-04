FROM python:3-alpine as pip-builder

WORKDIR /app

RUN apk add --no-cache \
    zlib-dev jpeg-dev libwebp-dev gcc
ENV PYTHONUSERBASE=/app/__pypackages__
RUN CC="cc -mavx2" pip install --user pillow-simd --global-option="build_ext" --global-option="--enable-webp"
RUN pip install --user mitmdump

FROM golang:alpine as go-builder

WORKDIR /temp

RUN apk add --no-cache git upx
RUN git clone -b v1.62.1 https://github.com/tailscale/tailscale.git ../tailscale
RUN go build -o tailscale.combined -tags ts_include_cli -ldflags="-s -w" ./cmd/tailscaled
RUN upx --lzma --best ./tailscale.combined

WORKDIR /app
RUN cp /temp/tailscale.combined ./
RUN ln -s tailscale.combined tailscale
RUN ln -s tailscale.combined tailscaled

FROM python:3-alpine

WORKDIR /app
COPY --from=pip-builder /app .
COPY --from=go-builder /app .
COPY flows.py .

RUN apk add --no-cache iptables \
 && sysctl -w net.ipv4.ip_forward=1 \
 && sysctl -w net.ipv6.conf.all.forwarding=1 \
 && iptables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 80 -j REDIRECT --to-port 8080 \
 && iptables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 443 -j REDIRECT --to-port 8080 \
 && ip6tables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 80 -j REDIRECT --to-port 8080 \
 && ip6tables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 443 -j REDIRECT --to-port 8080

ENV PYTHONUSERBASE=/app/__pypackages__
ENTRYPOINT sh -c "python -m mitmdump --listen-port 8080 --ssl-insecure -s flows.py --set stream_large_bodies=10m --ignore-hosts '(mzstatic|apple|icloud|mobilesuica|crashlytic|google-analytics|merpay|paypay|rakuten-bank|fate|colopl|rakuten-sec|line|kyash|plexure)' --set block_global=true --set flow_detail=1 --set http2=false --showhost --rawtcp --mode transparent & ./tailscale up --advertise-exit-node"
