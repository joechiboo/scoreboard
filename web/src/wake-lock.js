// 計分板放著不動也不能黑屏。切到背景時瀏覽器會自動放掉鎖，回到前景要重新要一次。
// 舊瀏覽器沒有這個功能，或省電模式拒絕時都略過，計分板照常用。
export function keepScreenOn(nav = navigator, doc = document) {
  if (!nav.wakeLock) return false
  const request = async () => {
    try {
      await nav.wakeLock.request('screen')
    } catch (err) {
      console.warn('螢幕常亮要求失敗', err)
    }
  }
  doc.addEventListener('visibilitychange', () => {
    if (doc.visibilityState === 'visible') request()
  })
  request()
  return true
}
