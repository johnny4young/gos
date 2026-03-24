class Gos < Formula
  desc "Go Switch - install and switch Go versions in seconds"
  homepage "https://github.com/johnny4young/gos"
  url "https://github.com/johnny4young/gos/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "FILL_AFTER_RELEASE"
  license "MIT"
  version "1.0.0"

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
