// 本地图片走原生的 EditorImageLoader（image-loader:// scheme），远程图片和 data URL 原样使用
const scheme = 'image-loader';

export function resolveImageURL(url: string) {
  if (url.includes('://') || url.startsWith('//') || url.startsWith('data:image/')) {
    return url;
  }

  return `${scheme}://${url}`;
}
