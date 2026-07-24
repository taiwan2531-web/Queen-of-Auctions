/*!
 * delist.js — 法拍物件「下架判定」單一真理源（deep module）
 * ------------------------------------------------------------------
 * 下架規則只在這裡定義一次，總覽（104woo.html）與每一張物件頁都消費它。
 * 規則：開標時刻 + DELIST_HOURS 小時後自動下架。
 *       開標時間為 "00:00" / 空 / 無法解析時，視為「時間未知」，
 *       保守以當日 17:00 起算，避免在真正開標前就下架。
 *       時區固定台灣 +08:00，與檢視者所在時區無關。
 *
 * 對外 interface（小）：
 *   Delist.isExpired(dateISO, time, nowMs?) -> boolean   純函式，不碰 DOM
 *   Delist.applyToPage()                    -> void       讀 body.dataset 套用下架 UI
 *   Delist.DELIST_HOURS                     -> number     下架時窗常數
 */
(function (global) {
  'use strict';

  var DELIST_HOURS = 3;

  // 內部：由 dateISO + time 算出開標時刻 Date；時間未知回退 17:00；無日期回 null
  function aucStart(dateISO, time) {
    if (!dateISO) return null;
    var m = String(time || '').replace(/：/g, ':').match(/(\d{1,2}):(\d{2})/);
    var hh = '17', mm = '00';                 // 預設：時間未知 → 保守 17:00
    if (m) {
      var h = m[1].length < 2 ? '0' + m[1] : m[1];
      var mi = m[2];
      if (!(h === '00' && mi === '00')) {      // "00:00" 是「未知」哨兵，維持 17:00
        hh = h; mm = mi;
      }
    }
    var t = new Date(dateISO + 'T' + hh + ':' + mm + ':00+08:00');
    return isNaN(t.getTime()) ? null : t;
  }

  // 純判斷式：這個開標時刻 + N 小時是否已過。可注入 nowMs 供測試。
  function isExpired(dateISO, time, nowMs) {
    var t = aucStart(dateISO, time);
    if (t == null) return false;
    if (nowMs == null) nowMs = Date.now();
    return nowMs - t.getTime() > DELIST_HOURS * 3600000;
  }

  // 物件頁專用：讀取 <body data-auction="YYYY-MM-DD" data-auction-time="HH:mm">
  // 若已過期，套上 expired class、改標題（隱藏語音由 CSS 的 html.expired 規則負責）。
  function applyToPage() {
    var b = (typeof document !== 'undefined') && document.body;
    if (!b || !b.dataset || !b.dataset.auction) return;
    if (isExpired(b.dataset.auction, b.dataset.auctionTime || '')) {
      document.documentElement.classList.add('expired');
      document.title = '物件已下架｜法拍找慧瑜';
    }
  }

  var Delist = { isExpired: isExpired, applyToPage: applyToPage, DELIST_HOURS: DELIST_HOURS };

  // 匯出：瀏覽器掛 global.Delist；CommonJS（測試用 node）也可 require
  global.Delist = Delist;
  if (typeof module !== 'undefined' && module.exports) module.exports = Delist;

  // 物件頁載入即套用；<script src> 置於語音 script 之前，故 body 已存在可同步執行，
  // 確保 expired class 在語音 player script 執行前就設好。
  if (typeof document !== 'undefined') {
    if (document.body) applyToPage();
    else document.addEventListener('DOMContentLoaded', applyToPage);
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
