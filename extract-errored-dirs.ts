import path from 'node:path';

const EXPECTED_RECOGNIZED_LINES = 8505;
const TARGET_LOG_FILE_PATH = path.resolve(__dirname, '../nas-migrate-logs/migrate-errors-20251219-025430.log');
const OUTPUT_FILE_PATH = path.resolve(__dirname, '../nas-migrate-logs/errored-dirs-20251219-025430.txt');
const ERROR_PREFIX = 'rsync: [receiver] mkstemp "/var/mnt/ibbangche/';
const END_OF_DIR_MARKER = '/._';

async function main() {
  const fileContent = await Bun.file(TARGET_LOG_FILE_PATH).text();
  const lines = fileContent.split('\n').map((line) => line.trim()).filter((line) => line.length > 0);

  let recognizedLineCount = 0;
  const erroredDirs = new Set<string>();

  for (const line of lines) {
    if (!line.startsWith(ERROR_PREFIX)) continue;

    recognizedLineCount++;

    const startIdx = ERROR_PREFIX.length;
    const endIdx = line.indexOf(END_OF_DIR_MARKER, startIdx);

    if (endIdx === -1) continue;

    const dirPath = line.substring(startIdx, endIdx + END_OF_DIR_MARKER.length - 2);

    erroredDirs.add(dirPath);
  }

  if (recognizedLineCount !== EXPECTED_RECOGNIZED_LINES) {
    console.warn(`Warning: Expected ${EXPECTED_RECOGNIZED_LINES} recognized lines, but found ${recognizedLineCount}.`);
  }

  const outputContent = Array.from(erroredDirs).join('\n');
  await Bun.write(OUTPUT_FILE_PATH, outputContent);

  console.log(`Extracted ${erroredDirs.size} unique errored directories to ${OUTPUT_FILE_PATH}`);
}

if (import.meta.main) {
  await main();
}