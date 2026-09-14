"""Keep README branding tied to the reviewed real artwork, not mock screenshots."""
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import struct
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
ASSETS = {
    'emblem-icon.png': ('44ea9aae6386521a3ed761433070206e1eeed2cd8ddece9358352ea491fc45cf', (1024, 1024)),
    'apple-mail-avatars.png': ('41a8b1846d0aaa6c97454da71689ec2ff9cffc97cc07009177cc1d4e6af367e1', (3296, 2200)),
}


class Images(HTMLParser):
    def __init__(self):
        super().__init__()
        self.images = []

    def handle_starttag(self, tag, attributes):
        if tag == 'img':
            self.images.append(dict(attributes))


class ReadmeBrandingTests(unittest.TestCase):
    def test_readme_leads_with_the_approved_native_icon(self):
        text = (ROOT / 'README.md').read_text()
        parser = Images()
        parser.feed(text)
        self.assertEqual(len(parser.images), 2)
        logo = parser.images[0]
        self.assertEqual(logo['src'], 'docs/images/emblem-icon.png')
        self.assertEqual((logo['width'], logo['height']), ('112', '112'))
        self.assertEqual(logo['alt'], 'Emblem app icon')
        self.assertLess(text.index(logo['src']), text.index('<h1 align="center">Emblem</h1>'))
        self.assertIn('A familiar face for your inbox.', text)

    def test_approved_assets_are_exact_originals_and_valid_pngs(self):
        for name, (expected_hash, expected_size) in ASSETS.items():
            with self.subTest(asset=name):
                data = (ROOT / 'docs/images' / name).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), expected_hash)
                self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
                self.assertEqual(struct.unpack('>II', data[16:24]), expected_size)
                offset = 8
                types = []
                while offset < len(data):
                    length = struct.unpack('>I', data[offset:offset+4])[0]
                    kind = data[offset+4:offset+8]
                    payload = data[offset+8:offset+8+length]
                    crc = struct.unpack('>I', data[offset+8+length:offset+12+length])[0]
                    self.assertEqual(zlib.crc32(kind + payload) & 0xffffffff, crc)
                    types.append(kind)
                    offset += 12 + length
                self.assertEqual(offset, len(data))
                self.assertEqual(types[0], b'IHDR')
                self.assertEqual(types[-1], b'IEND')
                self.assertIn(b'IDAT', types)

    def test_showcase_is_apple_mail_and_preview_is_not_stable(self):
        text = (ROOT / 'README.md').read_text()
        parser = Images()
        parser.feed(text)
        self.assertEqual(parser.images[1]['src'], 'docs/images/apple-mail-avatars.png')
        self.assertIn('Apple Mail', parser.images[1]['alt'])
        self.assertIn('Sender photos and brand logos in Apple Mail, synced through Apple Contacts.', text)
        self.assertIn('releases/tag/v0.20.0-rc.5', text)
        self.assertIn('releases/download/v0.19.0/', text)
        self.assertIn('Public Google review and multi-day acceptance remain separate gates.', text)
        self.assertIn('Apple silicon and Intel for 0.20.0 previews', text)


if __name__ == '__main__':
    unittest.main()
