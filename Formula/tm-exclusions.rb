# frozen_string_literal: true

# Homebrew formula aligned with the Makefile install layout:
#   bin/tm-exclusions          (from tm_exclusions.sh)
#   share/tm-exclusions/default.conf
# Same paths as `make install` with PREFIX=.../Cellar/.../VERSION (Homebrew prefix).
#
# Official tap updates (url, sha256, version) on each release tag via
# `.github/workflows/release.yml` and `qveys/homebrew-tools` — keep `install` in sync here and in the tap.
#
# `url`, `sha256` and `version` below describe the last *published* tarball and are
# bumped together, never individually: the sha256 of a release only exists once the
# tag is pushed. Release tooling (`make release`, auto-patch) must not touch them.
class TmExclusions < Formula
  desc "Time Machine exclusion manager for developer Macs"
  homepage "https://github.com/qveys/tm-exclusions"
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.3.0.tar.gz"
  sha256 "4da857c19504d9d0b1ee65e2145591ecb0acfb4d16165ea61f465569638d472e"
  license "MIT"
  version "1.3.0"

  depends_on :macos

  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "config/default.conf"
    (share/"tm-exclusions").install "config/extra-prunes.example.conf"
    (share/"tm-exclusions"/"locales").install Dir["locales/*.sh"]
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/tm-exclusions --version")
    assert_path_exists share/"tm-exclusions/default.conf"
    assert_path_exists share/"tm-exclusions/extra-prunes.example.conf"
    assert_path_exists share/"tm-exclusions/locales/en.sh"
    assert_path_exists share/"tm-exclusions/locales/fr.sh"
    assert_match "Utilisation", shell_output("#{bin}/tm-exclusions --lang fr --help")
  end
end
