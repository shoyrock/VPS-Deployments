# Test image for the VPS-Deployments scripts: lints every script and smoke-runs
# the menu/installer without touching a real VPS.
#   docker build -t vps-deploy-tests -f tests/Dockerfile .
#   docker run --rm vps-deploy-tests
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends bash shellcheck curl ca-certificates jq sudo \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
COPY . /repo
RUN chmod +x /repo/tests/run-tests.sh
CMD ["/repo/tests/run-tests.sh"]
