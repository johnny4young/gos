# Homebrew formula for gos (the central-tap migration).
#
# This file is the source template that lives in the app repo; the released
# formula lives in the tap (johnny4young/homebrew-tap, `Formula/gos.rb`). On each
# release, the formula in the tap is bumped to the new `version`, its `url` is
# pinned to the published source tarball, and its `sha256` is set to that
# tarball's checksum by the release workflow (`.github/workflows/release.yml`),
# which calls `scripts/update-homebrew-tap.sh --kind formula`. See RELEASING.md.
#
# The placeholder `sha256` below is a syntactically valid 64-hex-digit value so
# the template parses; the release process replaces it with the real tarball
# checksum before the tap commit. Never publish this placeholder to the tap.
class Gos < Formula
  desc "Go Switch - install and switch Go versions in seconds"
  homepage "https://github.com/johnny4young/gos"
  url "https://github.com/johnny4young/gos/archive/refs/tags/v0.0.0.tar.gz"
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  def install
    bin.install "gos.sh" => "gos"
    bash_completion.install "completions/gos.bash" => "gos"
    zsh_completion.install "completions/gos.zsh" => "_gos"
    fish_completion.install "completions/gos.fish"
  end

  test do
    assert_match "gos v#{version}", shell_output("#{bin}/gos version")
  end
end
