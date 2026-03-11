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

// ─── 사진 만료 처리 ───

const EXPIRE_DAYS = 7;
const CLEANUP_DAYS = 37; // 만료 후 30일

/**
 * 만료 사진 정리 로직 (스케줄 + 수동 공용)
 *
 * 1. 7일 경과 pending → Storage 삭제 + status: "expired"
 * 2. 37일 경과 expired → RTDB 항목 완전 삭제
 */
async function doCleanup() {
  const now = Date.now();
  const expireCutoff = now - EXPIRE_DAYS * 24 * 60 * 60 * 1000;
  const cleanupCutoff = now - CLEANUP_DAYS * 24 * 60 * 60 * 1000;
  const bucket = admin.storage().bucket("dcom-smart-frame.firebasestorage.app");

  const familiesSnap = await admin.database().ref("families").once("value");
  const families = familiesSnap.val();
  if (!families) return { expired: 0, cleaned: 0 };

  let expired = 0;
  let cleaned = 0;

  for (const [familyId, familyData] of Object.entries(families)) {
    const photoSync = familyData.photoSync;
    if (!photoSync) continue;

    for (const [photoId, photo] of Object.entries(photoSync)) {
      const { status, createdAt, storagePath } = photo;

      // 7일 만료: pending/downloading → expired
      if ((status === "pending" || status === "downloading") && createdAt < expireCutoff) {
        if (storagePath) {
          try {
            await bucket.file(storagePath).delete();
          } catch (e) {
            if (e.code !== 404) {
              console.error(`Storage 삭제 실패: ${storagePath}`, e.message);
            }
          }
        }
        await admin.database()
          .ref(`families/${familyId}/photoSync/${photoId}`)
          .update({ status: "expired", storagePath: null });
        expired++;
        console.log(`만료 처리: families/${familyId}/photoSync/${photoId}`);
      }

      // 37일 정리: expired → 완전 삭제
      if (status === "expired" && createdAt < cleanupCutoff) {
        await admin.database()
          .ref(`families/${familyId}/photoSync/${photoId}`)
          .remove();
        cleaned++;
        console.log(`RTDB 삭제: families/${familyId}/photoSync/${photoId}`);
      }
    }
  }

  return { expired, cleaned };
}

/**
 * 스케줄 함수: 6시간마다 자동 실행
 */
exports.cleanupExpiredPhotos = functions.pubsub
  .schedule("every 6 hours")
  .onRun(async () => {
    const result = await doCleanup();
    console.log(`만료 처리 완료: ${result.expired}건 만료, ${result.cleaned}건 삭제`);
    return null;
  });

/**
 * HTTP 함수: 테스트용 수동 호출
 */
exports.cleanupExpiredPhotosManual = functions.https.onRequest(async (req, res) => {
  const result = await doCleanup();
  res.json({
    success: true,
    expired: result.expired,
    cleaned: result.cleaned,
    timestamp: new Date().toISOString(),
  });
});
