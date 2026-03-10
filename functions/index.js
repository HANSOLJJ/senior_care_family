const functions = require("firebase-functions");
const admin = require("firebase-admin");
const fetch = require("node-fetch");

const serviceAccount = require("./dcom-smart-frame-firebase-adminsdk-fbsvc-592311d9ff.json");
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  databaseURL: "https://dcom-smart-frame-default-rtdb.firebaseio.com",
});

// null/undefined 필드를 제거하는 헬퍼
function removeEmpty(obj) {
  return Object.fromEntries(
    Object.entries(obj).filter(([_, v]) => v != null && v !== "")
  );
}

/**
 * 카카오 로그인 → Firebase Custom Token
 */
exports.kakaoCustomToken = functions.https.onCall(async (data, context) => {
  const { accessToken } = data;
  if (!accessToken) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "accessToken is required"
    );
  }

  const response = await fetch("https://kapi.kakao.com/v2/user/me", {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!response.ok) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Invalid Kakao access token"
    );
  }

  const kakaoUser = await response.json();
  const uid = `kakao:${kakaoUser.id}`;
  const kakaoAccount = kakaoUser.kakao_account || {};
  const profile = kakaoAccount.profile || {};

  const displayName = profile.nickname || undefined;
  const photoURL = profile.profile_image_url || undefined;
  const email = kakaoAccount.email || undefined;

  try {
    await admin.auth().getUser(uid);
    await admin.auth().updateUser(uid, removeEmpty({ displayName, photoURL }));
  } catch (e) {
    if (e.code === "auth/user-not-found") {
      await admin.auth().createUser(removeEmpty({ uid, displayName, photoURL, email }));
    } else {
      throw e;
    }
  }

  await admin.database().ref(`users/${uid}`).update({
    name: displayName || null,
    email: email || null,
    photoUrl: photoURL || null,
    provider: "kakao",
    updatedAt: admin.database.ServerValue.TIMESTAMP,
  });

  const customToken = await admin.auth().createCustomToken(uid);
  return { customToken };
});

/**
 * 네이버 OAuth 콜백 → 네이버 SDK Custom Tab으로 리다이렉트
 * (SDK가 code를 받아서 자체적으로 토큰 교환 처리)
 */
exports.naverCallback = functions.https.onRequest(async (req, res) => {
  const qs = new URLSearchParams(req.query).toString();
  const redirectUrl = `naver3rdpartylogin://authorize/?${qs}`;
  res.send(`<!DOCTYPE html><html><head>
    <meta http-equiv="refresh" content="0;url=${redirectUrl}">
    </head><body>
    <script>window.location.href="${redirectUrl}";</script>
    </body></html>`);
});

/**
 * 네이버 로그인 → Firebase Custom Token (카카오와 동일 방식)
 */
exports.naverCustomToken = functions.https.onCall(async (data, context) => {
  const { accessToken } = data;
  if (!accessToken) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "accessToken is required"
    );
  }

  const profileRes = await fetch("https://openapi.naver.com/v1/nid/me", {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const profileData = await profileRes.json();

  if (profileData.resultcode !== "00") {
    throw new functions.https.HttpsError(
      "unauthenticated",
      `Naver API error: ${profileData.message}`
    );
  }

  const naverUser = profileData.response;
  const uid = `naver:${naverUser.id}`;
  const displayName = naverUser.name || naverUser.nickname || undefined;
  const photoURL = naverUser.profile_image || undefined;
  const email = naverUser.email || undefined;

  try {
    await admin.auth().getUser(uid);
    await admin.auth().updateUser(uid, removeEmpty({ displayName, photoURL }));
  } catch (e) {
    if (e.code === "auth/user-not-found") {
      await admin.auth().createUser(removeEmpty({ uid, displayName, photoURL, email }));
    } else {
      throw e;
    }
  }

  await admin.database().ref(`users/${uid}`).update({
    name: displayName || null,
    email: email || null,
    photoUrl: photoURL || null,
    provider: "naver",
    updatedAt: admin.database.ServerValue.TIMESTAMP,
  });

  const customToken = await admin.auth().createCustomToken(uid);
  return { customToken };
});
