"""Builds TestBooks/sample.epub: a small Chinese/English EPUB3 used to test the reader."""
import zipfile, os

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "sample.epub")

zh = "落霞与孤鹜齐飞，秋水共长天一色。渔舟唱晚，响穷彭蠡之滨；雁阵惊寒，声断衡阳之浦。"
en = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness."

def chapter(n, title):
    paras = "\n".join(
        f"<p>{zh if i % 2 == 0 else en} （第 {n} 章 第 {i+1} 段）</p>" for i in range(40))
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head><title>{title}</title><link rel="stylesheet" href="../css/book.css"/></head>
<body><h1 id="top">{title}</h1>
<p>跳到 <a href="ch{3 - n if n < 3 else 1}.xhtml#sec">另一章的小节</a>。</p>
{paras}
<h2 id="sec">小节 {n}.1</h2>
{paras}
</body></html>"""

chapters = [(1, "第一章 滕王阁"), (2, "第二章 A Tale of Two Cities")]
nav = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head><body>
<nav epub:type="toc"><ol>
<li><a href="text/ch1.xhtml">第一章 滕王阁</a><ol><li><a href="text/ch1.xhtml#sec">小节 1.1</a></li></ol></li>
<li><a href="text/ch2.xhtml">第二章 A Tale of Two Cities</a><ol><li><a href="text/ch2.xhtml#sec">小节 2.1</a></li></ol></li>
</ol></nav></body></html>"""

opf = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">test-book-0001</dc:identifier>
<dc:title>测试之书 Test Book</dc:title>
<dc:creator>王勃 &amp; Charles Dickens</dc:creator>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="css" href="css/book.css" media-type="text/css"/>
<item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
<item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
</package>"""

container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

css = "body { font-family: serif; } p { font-size: 0.9em; text-indent: 2em; } h1 { text-align: center; }"

with zipfile.ZipFile(out, "w") as z:
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/css/book.css", css, compress_type=zipfile.ZIP_DEFLATED)
    for n, t in chapters:
        z.writestr(f"OEBPS/text/ch{n}.xhtml", chapter(n, t), compress_type=zipfile.ZIP_DEFLATED)
print("wrote", out)
