"""Read-only staged and extracted package validation; never executes payloads."""
import argparse
import hashlib
import json
import lzma
import struct
import zlib
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_logo(client, logo):
    # WPF embeds the PNG stream, unchanged, inside its .g.resources section.
    data = client.read_bytes()
    png = logo.read_bytes()
    name = 'images/avc-logo.png'
    require(name.encode('utf-16le') in data or name.encode() in data, 'Client embedded resource name missing')
    require(png in data, 'Exact source logo PNG bytes missing from Client assembly')
    require(png.startswith(b'\x89PNG\r\n\x1a\n'), 'Source logo is not PNG')


def verify_exe(path):
    data = path.read_bytes()
    require(data[:2] == b'MZ', f'Not a Windows executable: {path.name}')
    offset = struct.unpack_from('<I', data, 0x3C)[0]
    require(data[offset:offset + 4] == b'PE\0\0', f'Invalid PE: {path.name}')
    require(struct.unpack_from('<H', data, offset + 4)[0] == 0x8664, f'Not x64: {path.name}')


def inno_block(data, offset):
    # Inno Setup 6.7+/7: CRC32, Int64 stored length, compression byte,
    # followed by CRC32-protected 4096-byte subblocks (Stream.BlockReader.pas).
    checksum, length, compressed = struct.unpack_from('<IQB', data, offset)
    require(zlib.crc32(data[offset + 4:offset + 13]) == checksum, 'Inno block header CRC mismatch')
    cursor, end, chunks = offset + 13, offset + 13 + length, []
    require(end <= len(data), 'Truncated Inno block')
    while cursor < end:
        crc = struct.unpack_from('<I', data, cursor)[0]
        chunk = data[cursor + 4:min(cursor + 4100, end)]
        require(chunk and zlib.crc32(chunk) == crc, 'Inno subblock CRC mismatch')
        chunks.append(chunk)
        cursor += 4 + len(chunk)
    payload = b''.join(chunks)
    if not compressed:
        return payload
    prop, dictionary = struct.unpack_from('<BI', payload)
    lc, remainder = prop % 9, prop // 9
    lp, pb = remainder % 5, remainder // 5
    return lzma.decompress(payload[5:], format=lzma.FORMAT_RAW,
                           filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': dictionary, 'lc': lc, 'lp': lp, 'pb': pb}])


def verify_uninstaller(installer, version):
    # Inno uses its embedded Setup engine to generate unins000.exe at install
    # time. It is not a separately staged application or an archive payload.
    data = installer.read_bytes()
    magic = b'rDlPtS\xcd\xe6\xd7{\x0b*'
    positions, cursor = [], 0
    while True:
        cursor = data.find(magic, cursor)
        if cursor < 0:
            break
        positions.append(cursor)
        cursor += len(magic)
    require(len(positions) == 1, 'Expected one Inno loader offset table')
    offset = positions[0]
    require(struct.unpack_from('<I', data, offset + 12)[0] == 2, 'Unsupported Inno loader revision')
    table = data[offset:offset + 64]
    require(zlib.crc32(table[:60]) == struct.unpack_from('<I', table, 60)[0], 'Inno loader table CRC mismatch')
    total, exe_offset, size, crc, headers_offset, payload_offset = struct.unpack_from('<qqIIqq', table, 16)
    require(total == len(data) and 0 < exe_offset < len(data) and
            0 < headers_offset < len(data) and 0 < payload_offset < len(data), 'Invalid Inno loader offsets')
    engine = bytearray(inno_block(data, exe_offset))
    require(len(engine) == size, 'Embedded Setup engine size mismatch')
    # Undo Inno TransformCallInstructions version 3 before checking original CRC.
    i = 0
    while i < len(engine) - 4:
        if engine[i] in (0xE8, 0xE9):
            i += 1
            if engine[i + 3] in (0x00, 0xFF):
                relative = int.from_bytes(engine[i:i + 3], 'little') - ((i + 4) & 0xFFFFFF)
                if relative & 0x800000:
                    engine[i + 3] ^= 0xFF
                engine[i:i + 3] = (relative & 0xFFFFFF).to_bytes(3, 'little')
            i += 4
        else:
            i += 1
    require(zlib.crc32(engine) == crc, 'Embedded installer/uninstaller engine CRC mismatch')
    require(engine.startswith(b'MZ'), 'Embedded installer/uninstaller engine is not PE')
    for value in ('UninstallString', 'DisplayVersion', 'Publisher', 'unins'):
        require(value.encode('utf-16le') in engine or value.encode() in engine, f'Inno uninstall mechanism missing {value}')
    # Actual compiled primary headers identify this application and registration.
    require(data[headers_offset:headers_offset + 12] == b'Inno Setup S', 'Inno setup header version missing')
    encryption_offset = headers_offset + 64
    encryption_crc = struct.unpack_from('<I', data, encryption_offset)[0]
    encryption = data[encryption_offset + 4:encryption_offset + 53]
    require(zlib.crc32(encryption) == encryption_crc and encryption[0] == 0, 'Inno encryption header invalid or unexpected encrypted package')
    headers = inno_block(data, encryption_offset + 53)
    # First string fields of TSetupHeader in the pinned 7.0.0.3 data layout.
    names = ('app_name', 'app_versioned_name', 'app_id', 'app_copyright', 'publisher', 'publisher_url',
             'support_phone', 'support_url', 'updates_url', 'version', 'default_dir', 'default_group',
             'base_filename', 'uninstall_files_dir', 'uninstall_name', 'uninstall_icon', 'app_mutex',
             'default_user', 'default_organization', 'default_serial', 'readme', 'contact', 'comments',
             'modify_path', 'create_uninstall_registry_key', 'uninstallable', 'close_filter', 'setup_mutex',
             'changes_environment', 'changes_associations', 'architectures_allowed', 'architectures_64bit')
    fields, cursor = {}, 0
    for name in names:
        length = struct.unpack_from('<I', headers, cursor)[0]
        cursor += 4
        require(cursor + length <= len(headers) and length % 2 == 0, 'Invalid compiled header string')
        fields[name] = headers[cursor:cursor + length].decode('utf-16le')
        cursor += length
    for name, expected in {'app_name': 'AVC Public Access', 'publisher': 'Antelope Valley College',
                           'version': version, 'app_id': '{{A3FA2FB5-0AC3-420B-B327-3120154A0F52}',
                           'uninstallable': 'yes', 'create_uninstall_registry_key': 'yes',
                           'uninstall_files_dir': '{app}', 'uninstall_name': 'AVC Public Access',
                           'architectures_allowed': 'x64os', 'architectures_64bit': 'x64os'}.items():
        require(fields[name] == expected, f'Compiled package metadata mismatch: {name}')
    return hashlib.sha256(engine).hexdigest()


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--logo', type=Path, required=True)
    parser.add_argument('--extracted', type=Path)
    parser.add_argument('--compiler-log', type=Path)
    parser.add_argument('--installer', type=Path)
    args = parser.parse_args()
    stage = args.stage
    manifest_path = stage / 'Deployment/payload-manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    expected = {entry['path']: entry for entry in manifest['files']}
    actual = {p.relative_to(stage).as_posix() for p in stage.rglob('*') if p.is_file()}
    require(actual == set(expected) | {'Deployment/payload-manifest.json'}, 'Unexpected or missing staging files')
    allowed_config = {'Service/appsettings.json'}
    for relative, entry in expected.items():
        path = stage / relative
        require(not any(x.lower() in {'archive', 'finalrelease', 'bin', 'obj', 'publish', 'server'} for x in path.relative_to(stage).parts), 'Forbidden path')
        require(path.suffix.lower() not in {'.db', '.sqlite', '.sqlite3', '.mdf', '.ldf', '.pdb', '.cs', '.csproj', '.xaml', '.bak', '.old', '.zip', '.pfx', '.pem', '.key'}, f'Forbidden file: {relative}')
        require(path.suffix.lower() in {'.exe', '.dll', '.json', '.ps1'}, f'Unreviewed payload: {relative}')
        require(path.suffix.lower() != '.ps1' or relative == 'Deployment/Deployment.ps1', 'Unexpected deployment script')
        if path.name.startswith('appsettings'):
            require(relative in allowed_config, 'Unexpected application configuration')
        require(digest(path) == entry['sha256'] and path.stat().st_size == entry['bytes'], f'Staging hash mismatch: {relative}')
    configuration = json.loads((stage / 'Service/appsettings.json').read_text(encoding='utf-8-sig'))
    require(set(configuration) == {'PublicAccess', 'Logging'}, 'Unreviewed Service configuration sections')
    require(configuration['PublicAccess'] == {'ServerAddress': 'http://SERVER_ADDRESS:5000', 'Location': 'Pilot', 'HeartbeatSeconds': 15}, 'Unexpected or sensitive packaged Service settings')
    require(configuration['Logging'] == {'LogLevel': {'Default': 'Information', 'Microsoft.Hosting.Lifetime': 'Information'}}, 'Unreviewed logging settings')
    for project in ('Client', 'Service', 'Watchdog'):
        verify_exe(stage / project / f'AVCPublicAccess.{project}.exe')
        runtime = json.loads((stage / project / f'AVCPublicAccess.{project}.runtimeconfig.json').read_text())
        require('includedFrameworks' in runtime['runtimeOptions'], f'{project} is not self-contained')
    verify_logo(stage / 'Client/AVCPublicAccess.Client.dll', args.logo)
    if args.extracted:
        installed = args.extracted / 'app'
        mapped = {}
        for relative in actual:
            destination = relative[len('Watchdog/'):] if relative.startswith('Watchdog/') else relative
            require(destination not in mapped, 'Payload collision')
            mapped[destination] = stage / relative
        extracted = {p.relative_to(installed).as_posix() for p in installed.rglob('*') if p.is_file()}
        require(extracted == set(mapped), 'Installer file set differs from fresh staging')
        for relative, source in mapped.items():
            require(digest(installed / relative) == digest(source), f'Extracted hash mismatch: {relative}')
        verify_logo(installed / 'Client/AVCPublicAccess.Client.dll', args.logo)
        require(args.installer is not None, 'Actual installer required for engine inspection')
        engine_hash = verify_uninstaller(args.installer, manifest['version'])
        require(args.compiler_log is not None, 'Compiler log required for package inspection')
        log = args.compiler_log.read_text(encoding='utf-8-sig')
        require('Successful compile' in log, 'Inno compilation did not succeed')
        print(f'Extracted {len(mapped)} payload files; every SHA256 matches fresh staging; Inno installer/uninstaller engine and compiled ARP metadata verified (engine SHA256 {engine_hash}).')
    print(f'Staging verified: {len(actual)} files, three Windows x64 self-contained payloads, exact embedded AVC logo, sanitized config.')


if __name__ == '__main__':
    main()
