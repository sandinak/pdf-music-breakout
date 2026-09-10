class PdfMusicBreakout < Formula
  include Language::Python::Virtualenv

  desc "Split a combined music PDF into one printable PDF per instrument part"
  homepage "https://github.com/sandinak/pdf-music-breakout"
  url "https://github.com/sandinak/pdf-music-breakout/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "fcb557683365617be6fc4a78a94c50d1003603690a1bb9ac87f4108557f610dc"
  license "AGPL-3.0-or-later"

  depends_on "python@3.14"

  # PyMuPDF builds MuPDF from source when installed from its sdist, which is
  # slow and fragile. The published wheels are abi3 (one per architecture,
  # good for any Python 3.10+), so take those instead. :nounzip keeps them as
  # wheels -- a .whl is a zip, and Homebrew would otherwise unpack it.
  on_macos do
    on_arm do
      resource "pymupdf" do
        url "https://files.pythonhosted.org/packages/fa/01/3591f781b417b382a8487a2356e927acfe858b1043bab0ec47f6805bb109/pymupdf-1.28.2-cp310-abi3-macosx_11_0_arm64.whl", using: :nounzip
        sha256 "7113846b35dbf0a033f088e4f4fb543dabeb4b0b12c112966a1ca1ee2d5eacae"
      end
    end
    on_intel do
      resource "pymupdf" do
        url "https://files.pythonhosted.org/packages/b4/51/550c9a75c4ff3245cb4ecb7bb95cbe2ab7374230b8e2b7a1f7259444150b/pymupdf-1.28.2-cp310-abi3-macosx_10_15_x86_64.whl", using: :nounzip
        sha256 "5fc315b425ff1f7afdd1ea2f348205cb19b806767daae7ce4d64115799c2bae1"
      end
    end
  end

  on_linux do
    resource "pymupdf" do
      url "https://files.pythonhosted.org/packages/c7/06/dace3e27af26690cb20bead80dbac42941b0841eb689b8aabbd67dde16f0/pymupdf-1.28.2-cp310-abi3-manylinux_2_28_x86_64.whl", using: :nounzip
      sha256 "397d6715c1f0df7548a92d0afd8ce370fc48fa47aeefac16be2bc04a16a8227f"
    end
  end

  def install
    venv = virtualenv_create(libexec, "python3.14")

    # Homebrew's virtualenv_install_with_resources passes --no-binary=:all:,
    # which refuses wheels outright, so install the PyMuPDF wheel by hand.
    # The virtualenv itself is built --without-pip, so drive pip from the
    # host Python and point it at the venv, the way Homebrew does.
    python = Formula["python@3.14"].opt_bin/"python3.14"
    resource("pymupdf").stage do
      wheel = Dir["*.whl"].first
      system python, "-m", "pip", "--python=#{libexec}/bin/python", "install",
             "--no-deps", "--no-index", "--ignore-installed", wheel
    end

    venv.pip_install_and_link buildpath
    pkgshare.install "packaging/make-app.sh"
  end

  def caveats
    <<~EOS
      To review and correct the split before writing files:
        pdf-music-breakout --serve

      For a double-clickable launcher in ~/Applications:
        #{opt_pkgshare}/make-app.sh
    EOS
  end

  test do
    # Build a two-page book with a part name printed on each page, split it,
    # and check the parts come out named correctly.
    (testpath/"make.py").write <<~PYTHON
      import pymupdf
      doc = pymupdf.open()
      for part in ("Full Score", "Alto Saxophone"):
          page = doc.new_page(width=612, height=792)
          page.insert_text((42, 50), part, fontsize=11)
          page.insert_text((240, 46), "Brew Test Song", fontsize=22)
          page.insert_text((80, 400), "music", fontsize=10)
      doc.save("Brew Test Song-ALL.pdf")
    PYTHON
    system libexec/"bin/python", testpath/"make.py"

    output = shell_output("#{bin}/pdf-music-breakout '#{testpath}/Brew Test Song-ALL.pdf' --list")
    assert_match "Brew Test Song-Score.pdf", output
    assert_match "Brew Test Song-Alto_Sax.pdf", output

    system bin/"pdf-music-breakout", testpath/"Brew Test Song-ALL.pdf",
           "-o", testpath/"parts"
    assert_predicate testpath/"parts/Brew Test Song-Score.pdf", :exist?
    assert_predicate testpath/"parts/Brew Test Song-Alto_Sax.pdf", :exist?
  end
end
