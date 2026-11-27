// Downloads a file over HTTPS, following redirects and retrying transient
// failures. Used instead of curl for the playwright-ohos source and the
// playwright-core tarballs, so the build works on hosts where curl cannot
// reach GitHub or crashes.
//
// usage: node fetch.cjs <url> <output-file>

const fs = require('fs');
const https = require('https');

const MAX_REDIRECTS = 5;
const MAX_ATTEMPTS = 3;

const [url, outputPath] = process.argv.slice(2);
if (!url || !outputPath) {
  console.error('usage: node fetch.cjs <url> <output-file>');
  process.exit(2);
}

const download = (target, redirects, attempt) => new Promise((resolve, reject) => {
  const request = https.get(target, { headers: { 'User-Agent': 'ohos-ports-fetch' } }, (response) => {
    if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
      response.resume();
      if (redirects >= MAX_REDIRECTS) {
        reject(new Error(`too many redirects for ${url}`));
        return;
      }
      resolve(download(response.headers.location, redirects + 1, 0));
      return;
    }
    if (response.statusCode !== 200) {
      response.resume();
      reject(new Error(`unexpected status ${response.statusCode} for ${target}`));
      return;
    }
    // Write to a partial file first so a failed attempt never leaves a
    // truncated file that later steps would mistake for a complete download.
    const partialPath = `${outputPath}.part`;
    const stream = fs.createWriteStream(partialPath);
    response.pipe(stream);
    stream.on('finish', () => {
      stream.close(() => {
        fs.renameSync(partialPath, outputPath);
        resolve();
      });
    });
    stream.on('error', reject);
    response.on('error', reject);
  });
  request.on('error', (error) => {
    if (attempt + 1 < MAX_ATTEMPTS) {
      console.warn(`fetch: retrying ${target}: ${error.message}`);
      setTimeout(() => resolve(download(target, redirects, attempt + 1)), 2000);
    } else {
      reject(error);
    }
  });
  request.setTimeout(120000, () => request.destroy(new Error(`request timed out: ${target}`)));
});

download(url, 0, 0)
  .then(() => console.log(`fetch: downloaded ${outputPath}`))
  .catch((error) => {
    console.error(`fetch: download failed: ${error.message}`);
    process.exit(1);
  });
