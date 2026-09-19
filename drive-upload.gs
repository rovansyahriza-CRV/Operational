/**
 * Daily Report -> Google Drive uploader.
 *
 * CARA PASANG:
 * 1. Buka https://script.google.com/ -> New project.
 * 2. Hapus isi Code.gs bawaan, ganti dengan isi file ini.
 * 3. Ganti SHARED_SECRET di bawah dengan string acak sendiri (jangan dibiarkan kosong).
 * 4. Ganti TARGET_FOLDER_ID dengan ID folder Google Drive tujuan
 *    (buka folder tujuan di Drive, ambil ID dari URL: drive.google.com/drive/folders/<ID INI>).
 *    Kosongkan ('') kalau mau simpan di My Drive (root) punya akun yang deploy.
 * 5. Deploy -> New deployment -> pilih tipe "Web app".
 *    - Execute as: Me
 *    - Who has access: Anyone
 *    (Wajib "Anyone" karena yang manggil adalah halaman statis di GitHub Pages, bukan
 *    akun Google -- makanya proteksinya pakai SHARED_SECRET di atas, bukan login Google.)
 * 6. Copy URL Web App yang muncul, tempel ke DRIVE_APPS_SCRIPT_URL di progress.js.
 * 7. Isi juga DRIVE_SHARED_SECRET di progress.js dengan nilai SAMA PERSIS seperti di sini.
 *
 * CATATAN KEAMANAN: siapa pun yang tahu URL Web App ini BISA POST ke sini. SHARED_SECRET
 * mencegah orang random ngirim file sampah ke Drive kamu, tapi bukan proteksi setara akun
 * Google beneran -- jangan taruh SHARED_SECRET di tempat publik (repo publik, chat, dsb).
 */

var SHARED_SECRET = 'GANTI_DENGAN_STRING_ACAK_SENDIRI';
var TARGET_FOLDER_ID = ''; // kosongkan buat simpan di root My Drive

function doPost(e) {
  try {
    var body = JSON.parse(e.postData.contents);

    if (!SHARED_SECRET || body.secret !== SHARED_SECRET) {
      return jsonResponse({ status: 'error', message: 'Secret tidak cocok.' });
    }
    if (!body.pdfBase64 || !body.fileName) {
      return jsonResponse({ status: 'error', message: 'pdfBase64 dan fileName wajib diisi.' });
    }

    var folder = TARGET_FOLDER_ID ? DriveApp.getFolderById(TARGET_FOLDER_ID) : DriveApp.getRootFolder();
    var bytes = Utilities.base64Decode(body.pdfBase64);
    var blob = Utilities.newBlob(bytes, 'application/pdf', body.fileName);
    var file = folder.createFile(blob);

    return jsonResponse({ status: 'ok', fileId: file.getId(), url: file.getUrl() });
  } catch (err) {
    return jsonResponse({ status: 'error', message: String(err) });
  }
}

function jsonResponse(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
