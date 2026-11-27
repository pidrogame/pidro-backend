const openButton = document.querySelector("[data-open-ios]");
const androidStoreCapture = document.querySelector('[data-deferred-platform="android"]');

let androidPlatformMajor = null;

if (androidStoreCapture && navigator.userAgentData?.getHighEntropyValues) {
  navigator.userAgentData
    .getHighEntropyValues(["platform", "platformVersion"])
    .then(({ platform, platformVersion }) => {
      if (platform === "Android") androidPlatformMajor = platformVersion.split(".")[0];
    })
    .catch(() => {});
}

const osMajor = (platform) => {
  if (platform === "android") {
    return androidPlatformMajor || navigator.userAgent.match(/Android\s+(\d+)/i)?.[1];
  }

  return navigator.userAgent.match(/(?:CPU (?:iPhone )?OS|iPhone OS)\s+(\d+)/i)?.[1];
};

const screenClass = () => {
  const smallerDimension = Math.min(window.innerWidth, window.innerHeight);
  if (smallerDimension < 600) return "compact";
  if (smallerDimension < 900) return "medium";
  return "large";
};

const captureDeferredInvite = (link) => {
  const platform = link.dataset.deferredPlatform;
  const major = osMajor(platform);
  const locale = navigator.languages?.[0] || navigator.language;
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  if (!platform || !major || !locale || !timezone) return;

  const body = new URLSearchParams({
    platform,
    os_major: major,
    screen_class: screenClass(),
    locale,
    timezone,
  }).toString();

  const blob = new Blob([body], {
    type: "application/x-www-form-urlencoded;charset=UTF-8",
  });

  if (navigator.sendBeacon?.(link.dataset.deferredCapture, blob)) return;

  fetch(link.dataset.deferredCapture, {
    method: "POST",
    body,
    credentials: "omit",
    keepalive: true,
    headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" },
  }).catch(() => {});
};

// The reset page's Show/Hide (PID-515); without JavaScript the button stays hidden.
document.querySelectorAll("[data-reveal-password]").forEach((button) => {
  const input = document.getElementById(button.getAttribute("aria-controls"));
  button.hidden = false;

  button.addEventListener("click", () => {
    const shown = input.type === "text";
    input.type = shown ? "password" : "text";
    button.textContent = shown ? button.dataset.show : button.dataset.hide;
    button.setAttribute("aria-pressed", String(!shown));
  });
});

// A second click would post a burned token and show the refusal.
document.querySelectorAll(".invite-form").forEach((form) => {
  form.addEventListener("submit", () => {
    form.querySelector("button[type=submit]").disabled = true;
  });
});

document.querySelectorAll("[data-deferred-capture]").forEach((link) => {
  link.addEventListener("click", () => captureDeferredInvite(link));
});

if (openButton) {
  let fallbackTimer;

  const cancelFallback = () => {
    window.clearTimeout(fallbackTimer);
  };

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) cancelFallback();
  });
  window.addEventListener("pagehide", cancelFallback);

  openButton.addEventListener("click", (event) => {
    event.preventDefault();
    cancelFallback();

    const fallbackMessage = document.querySelector("[data-ios-fallback]");

    window.location.assign(openButton.href);

    fallbackTimer = window.setTimeout(() => {
      if (document.visibilityState !== "visible") return;
      if (fallbackMessage) fallbackMessage.hidden = false;
    }, 1500);
  });
}
