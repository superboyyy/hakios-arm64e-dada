# Build environment for the dada UEFI (image name hakios-uefi, used by base/tools/dada-build.sh).
# Build context: the uefi-dada tree, for its pip-requirements.txt:
#   docker build -t hakios-uefi -f uefi-dada/Dockerfile $HOME/dada-uefi-build
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    git mono-devel build-essential lld uuid-dev nasm gcc-aarch64-linux-gnu \
    python3 python3-git python3-pip python3-venv gettext locales gnupg ca-certificates \
    clang llvm curl make mtools device-tree-compiler acpica-tools python3-pyelftools \
 && rm -rf /var/lib/apt/lists/*
COPY pip-requirements.txt /tmp/pip-requirements.txt
RUN pip3 install --break-system-packages -r /tmp/pip-requirements.txt
WORKDIR /work
CMD ["/bin/bash"]
