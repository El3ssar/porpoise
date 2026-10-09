#!/usr/bin/env python3
"""Writes Sparkle's update feed (appcast.xml) for one release.

usage: make-appcast.py VERSION DMG DOWNLOAD_URL SIGNATURE [NOTES.md] > appcast.xml

The release workflow uploads it with each release; Porpoise reads
https://github.com/El3ssar/porpoise/releases/latest/download/appcast.xml, so the newest release is the feed.
NOTES.md (GitHub's generated release notes) becomes the notes shown in Sparkle's update window.
"""
import html
import os
import re
import sys
from email.utils import formatdate


def notes_html(md: str) -> str:
    """Just enough Markdown for GitHub's release notes: headings, bullet lists, links, bold, code."""
    def inline(t: str) -> str:
        t = html.escape(t)
        t = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', t)
        t = re.sub(r"(?<![\"'>])(https?://[^\s<]+)", r'<a href="\1">\1</a>', t)
        t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
        return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)

    out, in_list = [], False
    for line in md.splitlines():
        s = line.strip()
        bullet = re.match(r"^[*-] +(.*)", s)
        if in_list and not bullet:
            out.append("</ul>")
            in_list = False
        if not s or s.startswith("<!--"):
            continue
        if bullet:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(bullet.group(1))}</li>")
        elif m := re.match(r"^(#{1,6}) +(.*)", s):
            out.append(f"<h3>{inline(m.group(2))}</h3>")
        else:
            out.append(f"<p>{inline(s)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    version, dmg, url, signature = sys.argv[1:5]
    notes = open(sys.argv[5], encoding="utf-8").read() if len(sys.argv) == 6 else ""
    body = notes_html(notes) or f"<p>Porpoise {html.escape(version)}</p>"
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Porpoise</title>
    <link>https://github.com/El3ssar/porpoise</link>
    <item>
      <title>Porpoise {html.escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/El3ssar/porpoise/releases/tag/v{html.escape(version)}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{body.replace("]]>", "]]&gt;")}]]></description>
      <enclosure url="{html.escape(url, quote=True)}" length="{os.path.getsize(dmg)}" type="application/octet-stream"
                 sparkle:edSignature="{html.escape(signature, quote=True)}"/>
    </item>
  </channel>
</rss>""")


main()
