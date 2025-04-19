# Build stage
FROM archlinux/archlinux:latest AS builder

RUN pacman -Syu --noconfirm \
 && pacman -S --noconfirm curl tar xz

WORKDIR /opt
RUN curl -L "https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz" \
    -o zig.tar.xz \
  && tar -xf zig.tar.xz \
  && mv zig-linux-x86_64-0.14.0 zig \
  && ln -s /opt/zig/zig /usr/local/bin/zig


WORKDIR /app
COPY . .

RUN zig build 
# Run stage
FROM archlinux/archlinux:latest AS runner
WORKDIR /app
COPY --from=builder /app/zig-out/bin/johma_site_zig /usr/local/bin/app
COPY --from=builder /app/src /app/src
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/app"]