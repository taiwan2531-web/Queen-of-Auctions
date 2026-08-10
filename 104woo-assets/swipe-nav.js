/*
 * swipe-nav.js — 物件頁照片區的左右滑動切換
 *
 * 手機上在大圖區域滑動即可換物件：
 *   左滑（手指往左）-> 上一個物件
 *   右滑（手指往右）-> 下一個物件
 * 方向對應畫面上導覽列的位置：「⬅ 上物件」在左、「下物件 ➡」在右，
 * 往哪邊滑就去哪邊的物件。
 *
 * 目的地直接讀頁面既有的導覽連結，所以不需要每頁另外寫死網址；
 * 連結是 class="off"（沒有上／下一個）時該方向就不作用。
 */
(function () {
  "use strict";

  var mid = document.querySelector(".hero .mid");
  if (!mid || !("ontouchstart" in window)) return;

  // 從導覽列取出上／下物件的網址（class="off" 代表到頭了）
  function targetOf(label) {
    var links = document.querySelectorAll(".nav-row a");
    for (var i = 0; i < links.length; i++) {
      var a = links[i];
      if (a.textContent.indexOf(label) < 0) continue;
      if (a.classList.contains("off")) return null;
      var href = a.getAttribute("href");
      return href && href !== "#" ? href : null;
    }
    return null;
  }

  var MIN_DIST = 60;    // 至少要滑這麼多 px 才算數
  var MAX_TIME = 800;   // 太慢的拖曳不算滑動
  var RATIO = 1.5;      // 水平位移要明顯大於垂直，避免和上下捲動打架

  var x0 = 0, y0 = 0, t0 = 0, tracking = false;

  mid.addEventListener("touchstart", function (e) {
    if (e.touches.length !== 1) { tracking = false; return; }
    var t = e.touches[0];
    x0 = t.clientX; y0 = t.clientY; t0 = Date.now();
    tracking = true;
  }, { passive: true });

  mid.addEventListener("touchend", function (e) {
    if (!tracking) return;
    tracking = false;

    var t = e.changedTouches[0];
    var dx = t.clientX - x0;
    var dy = t.clientY - y0;
    if (Date.now() - t0 > MAX_TIME) return;
    if (Math.abs(dx) < MIN_DIST) return;
    if (Math.abs(dx) < Math.abs(dy) * RATIO) return;   // 判定為上下捲動

    var href = dx < 0 ? targetOf("上物件") : targetOf("下物件");
    if (href) location.href = href;
  }, { passive: true });

  mid.addEventListener("touchcancel", function () { tracking = false; }, { passive: true });
})();
