# frozen_string_literal: true

# Homebrew formula aligned with the Makefile install layout:
#   bin/tm-exclusions          (from tm_exclusions.sh)
#   share/tm-exclusions/default.conf
# Same paths as `make install` with PREFIX=.../Cellar/.../VERSION (Homebrew prefix).
#
# Official tap updates (url, sha256, version) on each release tag via
# `.github/workflows/release.yml` and `qveys/homebrew-tools` — keep `install` in sync here and in the tap.
class TmExclusions < Formula
  desc "Time Machine exclusion manager for developer Macs"
  homepage "https://github.com/qveys/tm-exclusions"
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "93d9f89e76f0b4c645340a1191d3d77d12a3156e0cbbd496a998d4c587b1cee2"
  license "MIT"
  version "1.1.0"

  depends_on :macos

  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "config/default.conf"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/tm-exclusions --version")
    assert_path_exists share/"tm-exclusions/default.conf"
  end
end
