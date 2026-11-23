# Signs an EFI application for Secure Boot with the Sprint signer (authenticode.sp).
# usage: sprint run --allow-read=DIR --allow-write=DIR os/boot/sbsign.sp KEY.pem CERT.pem IN.efi OUT.efi
import authenticode
import fs
import sys
let pe = fs.read_bytes(sys.args[2])
let signed = authenticode.sign(pe, fs.read_file(sys.args[0]), fs.read_file(sys.args[1]))
fs.write_bytes(sys.args[3], signed)
print("signed " .. sys.args[2] .. " -> " .. sys.args[3] .. " (" .. to_string(len(signed)) .. " bytes)")
