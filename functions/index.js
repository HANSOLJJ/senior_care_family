/**
 * Senior Care — Cloud Functions
 *
 * === 배포 방법 ===
 * cd functions
 * npm install              # 최초 1회 또는 의존성 변경 시
 * firebase deploy --only functions
 *
 * 특정 함수만 배포:
 * firebase deploy --only functions:kakaoCustomToken,functions:cleanupOrphanedData
 *
 * === Firebase Console에서 확인 ===
 * 1. https://console.firebase.google.com → dcom-smart-frame 프로젝트
 * 2. 왼쪽 메뉴 → 호스팅, 서버리스 → Functions
 * 3. 대시보드: 배포된 함수 목록, 리전, 트리거 타입, 마지막 배포 시간
 * 4. 로그: 각 함수 클릭 → "로그 보기" 또는 상단 "로그" 탭
 *    - 실행 시간, 에러, console.log 출력 전부 확인 가능
 *
 * === 함수 목록 ===
 * - kakaoCustomToken       : 카카오 로그인 → Firebase Custom Token (onCall)
 * - naverCustomToken       : 네이버 로그인 → Firebase Custom Token (onCall)
 * - cleanupExpiredPhotos   : 만료 사진 정리 — 6시간마다 자동 실행 (스케줄)
 * - cleanupExpiredPhotosManual : 만료 사진 정리 — 수동 HTTP 트리거
 * - cleanupOrphanedData    : 고아 데이터 정리 — 매일 새벽 3시 자동 실행 (스케줄)
 * - cleanupOrphanedDataManual : 고아 데이터 정리 — 수동 HTTP 트리거
 * - onPhotoDownloaded      : 사진 다운로드 완료 → 모든 Senior 완료 시 Storage 삭제 (RTDB 트리거)
 * - onReminderMediaDownloaded : 알림 미디어 다운로드 완료 → Storage 삭제 (RTDB 트리거)
 * - onReminderDeleted      : 알림 삭제 → Storage 파일 삭제 (RTDB 트리거)
 *
 * === 수동 테스트 ===
 * 브라우저에서 URL 호출:
 * https://us-central1-dcom-smart-frame.cloudfunctions.net/cleanupExpiredPhotosManual
 * https://us-central1-dcom-smart-frame.cloudfunctions.net/cleanupOrphanedDataManual
 */

const functions = require("firebase-functions");
const admin = require("firebase-admin");
const fetch = require("node-fetch");

const serviceAccount = require("./dcom-smart-frame-firebase-adminsdk-fbsvc-592311d9ff.json");
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  databaseURL: "https://dcom-smart-frame-default-rtdb.firebaseio.com",
  storageBucket: "dcom-smart-frame.firebasestorage.app",
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
      const { status, createdAt, storagePath, thumbPath } = photo;

      // Storage 파일 삭제 헬퍼
      const deleteFile = async (path) => {
        if (!path) return;
        try {
          await bucket.file(path).delete();
        } catch (e) {
          if (e.code !== 404) console.error(`Storage 삭제 실패: ${path}`, e.message);
        }
      };

      // 7일 만료: pending/downloading → expired + 원본 Storage 삭제 + 썸네일 삭제
      if ((status === "pending" || status === "downloading") && createdAt < expireCutoff) {
        await deleteFile(storagePath);
        await deleteFile(thumbPath);
        await admin.database()
          .ref(`families/${familyId}/photoSync/${photoId}`)
          .update({ status: "expired", storagePath: null, thumbPath: null });
        expired++;
        console.log(`만료 처리: families/${familyId}/photoSync/${photoId}`);
      }

      // done → 원본 Storage 잔여 삭제 보험 (thumbPath는 유지)
      if (status === "done" && storagePath) {
        await deleteFile(storagePath);
        await admin.database()
          .ref(`families/${familyId}/photoSync/${photoId}/storagePath`)
          .remove();
        cleaned++;
        console.log(`done 원본 Storage 삭제 (보험): ${storagePath}`);
      }

      // 37일 정리: expired → RTDB 완전 삭제 + 썸네일 삭제
      if (status === "expired" && createdAt < cleanupCutoff) {
        await deleteFile(thumbPath); // expired 처리 시 지웠어도 재시도 무해
        await admin.database()
          .ref(`families/${familyId}/photoSync/${photoId}`)
          .remove();
        cleaned++;
        console.log(`RTDB 삭제: families/${familyId}/photoSync/${photoId}`);
      }

      // deleted 상태는 더 이상 사용하지 않음.
      // Family 앱이 RTDB 노드를 즉시 removeValue() → onPhotoDeleted(onDelete)가 처리.
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

// ─── 고아 데이터 정리 (와치독) ───

const DEVICE_OFFLINE_DAYS = 7;

/**
 * 고아 데이터 정리 로직 (스케줄 + 수동 공용)
 *
 * Step 1: 유령 디바이스 정리 (offline + 7일)
 * Step 2: 가족 내 유령 디바이스 정리
 * Step 3: 고아 가족 정리 (멤버 0 + 디바이스 0)
 * Step 4: 고아 페어링 코드 정리
 * Step 5: 고아 유저 참조 정리
 * Step 6: 고아 Storage 정리 (RTDB에 없는 familyId의 Storage 파일)
 */
async function doOrphanCleanup() {
  const db = admin.database();
  const now = Date.now();
  const offlineCutoff = now - DEVICE_OFFLINE_DAYS * 24 * 60 * 60 * 1000;
  const result = { devices: 0, familyDevices: 0, families: 0, pairingCodes: 0, userRefs: 0 };

  // Step 1: 유령 디바이스 정리
  const devicesSnap = await db.ref("devices").once("value");
  const devices = devicesSnap.val() || {};
  const activeDeviceIds = new Set();

  for (const [deviceId, device] of Object.entries(devices)) {
    const lastSeen = device.lastSeen || 0;
    const online = device.online || false;
    if (!online && lastSeen < offlineCutoff) {
      // /families/{fid}/devices/{did}도 삭제
      const fid = device.familyId;
      if (fid) {
        await db.ref(`families/${fid}/devices/${deviceId}`).remove();
      }
      await db.ref(`devices/${deviceId}`).remove();
      result.devices++;
      console.log(`Step1: 유령 디바이스 삭제: ${deviceId} (familyId: ${fid}, lastSeen: ${new Date(lastSeen).toISOString()})`);
    } else {
      activeDeviceIds.add(deviceId);
    }
  }

  // Step 2~5: 가족 단위 정리
  const familiesSnap = await db.ref("families").once("value");
  const families = familiesSnap.val() || {};

  const activeFamilyIds = new Set();

  for (const [familyId, family] of Object.entries(families)) {
    // Step 2: 가족 내 유령 디바이스 정리
    // - /devices/에 없거나
    // - /devices/{did}/familyId가 이 가족이 아닌 경우 (다른 가족으로 이동함)
    const familyDevices = family.devices || {};
    for (const deviceId of Object.keys(familyDevices)) {
      const globalDevice = devices[deviceId];
      const isOrphan = !activeDeviceIds.has(deviceId) ||
        (globalDevice && globalDevice.familyId && globalDevice.familyId !== familyId);
      if (isOrphan) {
        await db.ref(`families/${familyId}/devices/${deviceId}`).remove();
        result.familyDevices++;
        console.log(`Step2: 가족 내 유령 디바이스 삭제: families/${familyId}/devices/${deviceId}`);
      }
    }

    // Step 3: 고아 가족 정리 (멤버 0 + 디바이스 0 → 완전히 버려진 가족)
    const membersSnap = await db.ref(`families/${familyId}/members`).once("value");
    const devicesSnap2 = await db.ref(`families/${familyId}/devices`).once("value");
    const memberCount = membersSnap.numChildren();
    const deviceCount = devicesSnap2.numChildren();

    if (memberCount === 0 && deviceCount === 0) {
      // 페어링 코드도 삭제
      const pairingCode = family.pairingCode;
      if (pairingCode) {
        await db.ref(`pairingCodes/${pairingCode}`).remove();
      }
      await db.ref(`families/${familyId}`).remove();
      result.families++;
      console.log(`Step3: 고아 가족 삭제: ${familyId} (pairingCode: ${pairingCode})`);
    } else {
      activeFamilyIds.add(familyId);
    }
  }

  // Step 4: 고아 페어링 코드 정리
  const codesSnap = await db.ref("pairingCodes").once("value");
  const codes = codesSnap.val() || {};
  for (const [code, familyId] of Object.entries(codes)) {
    if (!activeFamilyIds.has(familyId)) {
      await db.ref(`pairingCodes/${code}`).remove();
      result.pairingCodes++;
      console.log(`Step4: 고아 페어링 코드 삭제: ${code} → ${familyId}`);
    }
  }

  // Step 5: 고아 유저 참조 정리
  const usersSnap = await db.ref("users").once("value");
  const users = usersSnap.val() || {};
  for (const [uid, userData] of Object.entries(users)) {
    const familyIds = userData.familyIds || {};
    for (const familyId of Object.keys(familyIds)) {
      if (!activeFamilyIds.has(familyId)) {
        await db.ref(`users/${uid}/familyIds/${familyId}`).remove();
        await db.ref(`users/${uid}/familyNames/${familyId}`).remove();
        result.userRefs++;
        console.log(`Step5: 고아 유저 참조 삭제: users/${uid}/familyIds/${familyId}`);
      }
    }
  }

  // Step 6: 고아 Storage 정리 (RTDB에 없는 familyId의 Storage 파일 삭제)
  try {
    const bucket = admin.storage().bucket("dcom-smart-frame.firebasestorage.app");
    const [files] = await bucket.getFiles({ prefix: "families/" });
    const checkedFamilies = new Set();
    for (const file of files) {
      // families/{fid}/... 에서 fid 추출
      const parts = file.name.split("/");
      if (parts.length < 2) continue;
      const fid = parts[1];
      if (checkedFamilies.has(fid)) continue;
      checkedFamilies.add(fid);

      if (!families[fid]) {
        // RTDB에 없는 family → 해당 family의 Storage 파일 전부 삭제
        const [familyFiles] = await bucket.getFiles({ prefix: `families/${fid}/` });
        for (const f of familyFiles) {
          await f.delete();
          result.storageFiles = (result.storageFiles || 0) + 1;
        }
        console.log(`Step6: 고아 Storage 삭제: families/${fid}/ (${familyFiles.length}개 파일)`);
      }
    }
  } catch (e) {
    console.error("Step6 Storage 정리 실패:", e.message);
  }

  return result;
}

/**
 * 스케줄 함수: 매일 새벽 3시 (KST) 실행
 * UTC 기준 18:00 = KST 03:00
 */
exports.cleanupOrphanedData = functions.pubsub
  .schedule("every day 18:00")
  .timeZone("UTC")
  .onRun(async () => {
    const result = await doOrphanCleanup();
    console.log(`고아 정리 완료: 디바이스=${result.devices}, 가족디바이스=${result.familyDevices}, 가족=${result.families}, 코드=${result.pairingCodes}, 유저참조=${result.userRefs}, Storage=${result.storageFiles || 0}`);
    return null;
  });

/**
 * HTTP 함수: 테스트용 수동 호출
 */
exports.cleanupOrphanedDataManual = functions.https.onRequest(async (req, res) => {
  const result = await doOrphanCleanup();
  res.json({
    success: true,
    ...result,
    timestamp: new Date().toISOString(),
  });
});

// ============================================================
// RTDB 트리거: 사진 다운로드 완료 → 모든 Senior 완료 시 Storage 삭제
// ============================================================
exports.onPhotoDownloaded = functions.database
  .ref("/families/{familyId}/photoSync/{photoId}/downloadedBy/{deviceId}")
  .onCreate(async (snapshot, context) => {
    const { familyId, photoId } = context.params;
    const db = admin.database();

    // 현재 사진 메타 읽기
    const photoSnap = await db
      .ref(`families/${familyId}/photoSync/${photoId}`)
      .once("value");
    const photo = photoSnap.val();
    if (!photo || photo.status === "done") return null;

    // downloadedBy 수
    const downloadedBy = photo.downloadedBy || {};
    const downloadedCount = Object.keys(downloadedBy).length;

    // 가족 내 Senior 기기 수
    const devicesSnap = await db
      .ref(`families/${familyId}/devices`)
      .once("value");
    const devices = devicesSnap.val() || {};
    const seniorCount = Object.keys(devices).length;

    console.log(
      `onPhotoDownloaded: ${photoId} — ${downloadedCount}/${seniorCount} Senior 완료`
    );

    if (downloadedCount < seniorCount) return null;

    // 모든 Senior 다운로드 완료 → 원본 Storage 삭제 + status: done
    // (썸네일 thumbPath는 영구 보관 — Family 앱 표시용)
    if (photo.storagePath) {
      try {
        await admin.storage().bucket().file(photo.storagePath).delete();
        console.log(`Storage 원본 삭제: ${photo.storagePath}`);
      } catch (e) {
        console.warn(`Storage 원본 삭제 실패 (무시): ${e.message}`);
      }
    }

    await db.ref(`families/${familyId}/photoSync/${photoId}`).update({
      status: "done",
      storagePath: null,
      completedAt: admin.database.ServerValue.TIMESTAMP,
    });

    return null;
  });

// ============================================================
// RTDB 트리거: 사진 RTDB 노드 삭제 → 썸네일 Storage 삭제
// Family 앱이 deletePhoto() 시 노드를 즉시 remove() → 이 트리거 발동
// ============================================================
exports.onPhotoDeleted = functions.database
  .ref("/families/{familyId}/photoSync/{photoId}")
  .onDelete(async (snapshot) => {
    const photo = snapshot.val();
    const thumbPath = photo && photo.thumbPath;
    if (!thumbPath) return null;

    try {
      await admin.storage().bucket().file(thumbPath).delete();
      console.log(`onPhotoDeleted: 썸네일 삭제 ${thumbPath}`);
    } catch (e) {
      console.warn(`onPhotoDeleted: 썸네일 삭제 실패 (무시): ${e.message}`);
    }

    return null;
  });

// ============================================================
// RTDB 트리거: 알림 미디어 다운로드 완료 → Storage 삭제
// ============================================================
exports.onReminderMediaDownloaded = functions.database
  .ref("/families/{familyId}/reminders/{reminderId}/mediaDownloaded")
  .onUpdate(async (change, context) => {
    const after = change.after.val();
    if (after !== true) return null;

    const { familyId, reminderId } = context.params;
    const db = admin.database();

    // 알림 메타 읽기
    const reminderSnap = await db
      .ref(`families/${familyId}/reminders/${reminderId}`)
      .once("value");
    const reminder = reminderSnap.val();
    if (!reminder) return null;

    // Storage 미디어 삭제
    const storagePath = `families/${familyId}/reminders/${reminderId}`;
    try {
      const [files] = await admin
        .storage()
        .bucket()
        .getFiles({ prefix: storagePath });
      for (const file of files) {
        await file.delete();
        console.log(`Storage 삭제: ${file.name}`);
      }
    } catch (e) {
      console.warn(`Storage 삭제 실패 (무시): ${e.message}`);
    }

    return null;
  });

// ============================================================
// RTDB 트리거: 알림 삭제 → Storage 파일 삭제
// ============================================================
exports.onReminderDeleted = functions.database
  .ref("/families/{familyId}/reminders/{reminderId}")
  .onDelete(async (snapshot, context) => {
    const { familyId, reminderId } = context.params;
    const reminder = snapshot.val();

    // Storage 미디어 삭제
    const storagePath = `families/${familyId}/reminders/${reminderId}`;
    try {
      const [files] = await admin
        .storage()
        .bucket()
        .getFiles({ prefix: storagePath });
      for (const file of files) {
        await file.delete();
        console.log(`onReminderDeleted: Storage 삭제 ${file.name}`);
      }
    } catch (e) {
      console.warn(`onReminderDeleted: Storage 삭제 실패 (무시): ${e.message}`);
    }

    return null;
  });
