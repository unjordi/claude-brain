// set-icon.swift <icono.icns|png> <archivo-destino>
// Incrusta un ícono custom en CUALQUIER archivo vía la API de Cocoa (NSWorkspace.setIcon), que
// escribe el recurso + el flag "tiene ícono custom" de forma confiable — a diferencia de Rez/SetFile,
// que dejan el resource fork a medias. Se usa para brandear el daemon `claude-brain-fetch` (un script
// pelón) en "Elementos de inicio" con el ícono de Claude Brain. Sin dependencias externas.
import AppKit
let a = CommandLine.arguments
guard a.count == 3, let img = NSImage(contentsOfFile: a[1]) else {
    FileHandle.standardError.write(Data("uso: set-icon.swift <icono> <archivo>\n".utf8)); exit(1)
}
exit(NSWorkspace.shared.setIcon(img, forFile: a[2], options: []) ? 0 : 2)
