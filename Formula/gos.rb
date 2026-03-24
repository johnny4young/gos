class Gos < Formula
  desc "Go Switch - install and switch Go versions in seconds"
  homepage "https://github.com/johnny4young/gos"
  url "https://github.com/johnny4young/gos/archive/refs/tags/vv.1.1.0.tar.gz"
  sha256 "0881fad7ddf3ca2a34586d1b46db46cb58b6f393979a73086de0991218a5e650"
  license "MIT"
  version "v.1.1.0"

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
