# macOS (Apple Silicon) prerequisites of the dev environment: the single source of truth.
# Install with `make brew-bundle` (= brew bundle --file=Brewfile). `make doctor` and the
# macOS entry points (machine-init, cluster-up, deploy) check these formulae.
brew "bash"            # bash >= 4 (macOS ships 3.2)
brew "make"            # GNU make >= 3.82 (put $(brew --prefix)/opt/make/libexec/gnubin first in PATH)
brew "podman"          # client + podman machine (rootful VM with the k3s node and Zot)
brew "opentofu"
brew "helm"
brew "kubernetes-cli"  # kubectl
brew "jq"
brew "python-yq"       # the Python yq (jq syntax); NOT the "yq" formula (Go, mikefarah)
brew "skopeo"
brew "openssl@3"       # LibreSSL in macOS lacks options the CA scripts use
brew "git"
brew "shellcheck"      # make lint
