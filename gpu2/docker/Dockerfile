FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential meson ninja-build pkg-config python3 python3-mako python3-yaml python3-packaging \
    bison flex glslang-tools libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev libelf-dev \
    vulkan-tools libvulkan-dev spirv-tools python3-pip git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN pip3 install --break-system-packages 'meson>=1.5,<1.10'
RUN pip3 install --break-system-packages vulkan
