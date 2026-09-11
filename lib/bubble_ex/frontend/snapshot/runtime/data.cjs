// Recognize bytes, not a caller-supplied MIME label. Never treat HTML as an image.
function rasterData(url) {
  const match = /^data:(?:image\/(?:png|jpeg|gif|webp|avif))?(?:;charset=[^;,]+)?;base64,([A-Za-z0-9+/=\s]+)$/i.exec(url);
  if (!match) return null;
  const compact=match[1].replace(/\s/g,'');
  if (compact.length > 40 * 1024 * 1024 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(compact)) return null;
  const body=Buffer.from(compact,'base64');
  let mime;
  if (body.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex'))) mime='image/png';
  else if (body.subarray(0,3).equals(Buffer.from('ffd8ff','hex'))) mime='image/jpeg';
  else if (/^GIF8[79]a$/.test(body.subarray(0,6).toString())) mime='image/gif';
  else if (body.subarray(0,4).toString()==='RIFF' && body.subarray(8,12).toString()==='WEBP') mime='image/webp';
  else if (body.subarray(4,8).toString()==='ftyp' && ['avif','avis'].includes(body.subarray(8,12).toString())) mime='image/avif';
  return mime ? {body,mime} : null;
}
function scanText(text, decodedRasters = []) {
  // Binary image encodings are not text credentials. SVG is deliberately excluded.
  return text.replace(/data:(?:image\/(?:png|jpeg|gif|webp|avif))?(?:;charset=[^;,"'<>\s]+)?;base64,[A-Za-z0-9+/=]+/gi, value => { const raster=rasterData(value); if (!raster) return value; decodedRasters.push(raster.body.toString('latin1')); return '[captured raster bytes]'; });
}
module.exports={rasterData,scanText};
