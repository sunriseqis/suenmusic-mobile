#!/usr/bin/env node
/**
 * 鸿蒙 NEXT 客户端静态资源同步脚本：
 * 将同级 suenmusic-server/web/dist/ 静态构建产物同步至 hw/entry/src/main/resources/rawfile/。
 *
 * 用法：
 *   node scripts/sync-hw.mjs
 */

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, rmSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const WEB_DIR = join(ROOT, '../suenmusic-server/web');
const DIST_DIR = join(WEB_DIR, 'dist');
const HW_RAWFILE_DIR = join(ROOT, 'hw/entry/src/main/resources/rawfile');

function log(msg) {
  console.log(`[sync-hw] ${msg}`);
}

// 1. 若 web/dist 不存在或包含未编译代码，先编译 Web
if (!existsSync(join(DIST_DIR, 'index.html'))) {
  log('web/dist 产物不存在，开始执行 npm run build...');
  execFileSync('npm', ['run', 'build'], { cwd: WEB_DIR, stdio: 'inherit' });
}

// 2. 准备目标 rawfile 目录
if (existsSync(HW_RAWFILE_DIR)) {
  rmSync(HW_RAWFILE_DIR, { recursive: true, force: true });
}
mkdirSync(HW_RAWFILE_DIR, { recursive: true });

// 3. 复制 web/dist 产物至 rawfile
log(`复制静态资源: ${DIST_DIR} → ${HW_RAWFILE_DIR}`);
cpSync(DIST_DIR, HW_RAWFILE_DIR, { recursive: true });

// 保证 .gitkeep 存在以防空目录或 gitignore 问题
writeFileSync(join(HW_RAWFILE_DIR, '.gitkeep'), '');

// 4. 统计文件数量与总大小
function getDirStats(dir) {
  let count = 0;
  let totalBytes = 0;
  for (const item of readdirSync(dir)) {
    const full = join(dir, item);
    const s = statSync(full);
    if (s.isDirectory()) {
      const sub = getDirStats(full);
      count += sub.count;
      totalBytes += sub.totalBytes;
    } else {
      count++;
      totalBytes += s.size;
    }
  }
  return { count, totalBytes };
}

const stats = getDirStats(HW_RAWFILE_DIR);
log(`✔ 鸿蒙静态资源同步完成！共 ${stats.count} 个文件，总计 ${(stats.totalBytes / 1024 / 1024).toFixed(2)} MB`);
