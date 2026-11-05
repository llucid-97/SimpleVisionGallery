#!/usr/bin/env python3
# Target audience: agents. Capture the exact production log interpolation with a memory-only test sink.
from pathlib import Path
import re
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
view=root/'SimpleVisionGallery/Gallery/GalleryViewerView.swift'
s=view.read_text()
for p in (root/'SimpleVisionGallery').rglob('*.swift'):
    assert not re.search(r'\b(print|debugPrint|NSLog|os_log|dump)\s*\(',p.read_text()), f'Unreviewed raw log call: {p.name}'
a=s.index('                let error = error as NSError')
b=s.index('\n            }',a)
body=s[a:b]
helper=s[s.index('enum GalleryLogRedaction {'):].split('\n}\n',1)[0]+'\n}\n'
assert 'localizedDescription' not in body
assert 'privacy: .private' in body
harness='''
import Foundation
import CryptoKit
// A test sink captures even private fields, so privacy markup cannot hide a leak.
enum Privacy { case `private`, `public` }
struct LogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var text: String
    init(stringLiteral value: String) { text=value }
    init(stringInterpolation: StringInterpolation) { text=stringInterpolation.text }
    struct StringInterpolation: StringInterpolationProtocol {
        var text=""
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) { text += value }
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { text += String(describing:value) }
    }
}
struct Logger {
    static var output=""
    init(subsystem: String, category: String) {}
    func error(_ message: LogMessage) { Self.output=message.text }
}
''' + helper + '\nfunc actualResizeLog(_ error: Error) {\n'+body+'\n}\n' + '''
let title="FAKE_PRIVATE_ALBUM_7db0", filename="FAKE_PRIVATE_FILE_917b.jpg", id="FAKE_PRIVATE_ID_453a"
let path="/Users/generated/"+filename, location="FAKE_PRIVATE_LOCATION_9df2"
let marker=[title,filename,id,path,location].joined(separator:" ")
let error=NSError(domain:marker,code:73,userInfo:[NSLocalizedDescriptionKey:marker])
precondition(error.localizedDescription.contains(title))
actualResizeLog(error)
for forbidden in [title,filename,id,path,location] { precondition(!Logger.output.contains(forbidden)) }
precondition(Logger.output.contains("code=73") && Logger.output.contains("domain="))
precondition(GalleryLogRedaction.token(title)==GalleryLogRedaction.token(title))
precondition(GalleryLogRedaction.token(title) != GalleryLogRedaction.token(filename))
precondition(GalleryLogRedaction.token(title).count==16)
print(GalleryLogRedaction.token(title))
'''
with tempfile.TemporaryDirectory(prefix='svg-redaction-') as tmp:
    d=Path(tmp);f=d/'main.swift';f.write_text(harness)
    subprocess.run(['swiftc','-swift-version','5',str(f),'-o',str(d/'check')],check=True)
    first=subprocess.check_output([str(d/'check')],text=True).strip()
    second=subprocess.check_output([str(d/'check')],text=True).strip()
    assert first != second, 'Salt must change between process launches'
print('PASS: production log interpolation contains no fake title/filename/ID/path/location/raw error, even private fields; same-run tokens stable, new launch differs; raw-log source guard clean')
