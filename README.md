# IGRestore

Restore backup app-data của XoaInfo cho Instagram mà không cần XoaInfo.

## Chuẩn bị

Copy folder backup vào:
```text
/var/jb/var/mobile/Documents/IGRestore/
```

Ví dụ:
```text
/var/jb/var/mobile/Documents/IGRestore/1666439634.324285/
  com.burbn.instagram.tar.gzip
  group.com.burbn.instagram_groupShared.tar.gzip
  group.com.facebook.family_groupShared.tar.gzip
  SytemFile
```

Hoặc copy trực tiếp các file `.tar.gzip` vào `/var/jb/var/mobile/Documents/IGRestore/`.

## Restore

Tạo file trigger:
```bash
touch /var/jb/var/mobile/Documents/IGRestore/restore
```

Mở Instagram. Tweak sẽ:
1. Đọc `com.burbn.instagram.tar.gzip` → container Instagram.
2. Đọc 2 file group `.tar.gzip` → app group tương ứng.
3. Ghi log, đổi `restore` thành `restore.done`/`restore.failed`.
4. Nếu thành công, kill Instagram.
5. Mở lại Instagram.

Log:
```text
/var/jb/var/mobile/Documents/IGRestore/IGRestore.log
```

## Giới hạn quan trọng

Tweak **không restore keychain**. `sessionid` nằm trong keychain, không có trong các file `.tar.gzip`.

- Nếu keychain trên máy vẫn còn session của account này → mở IG sẽ tự login.
- Nếu keychain không còn → phải đăng nhập lại bằng mật khẩu/2FA.
- `SytemFile` là ZIP mã hoá, tweak này không giải mã/khôi phục keychain từ đó.

Tweak cũng không xoá sạch container cũ; nó ghi đè file từ backup. Nếu preferences bị cache bởi `cfprefsd`, có thể cần respring/reboot userspace để nhận đầy đủ.
