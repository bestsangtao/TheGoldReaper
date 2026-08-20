/**
 * Google Sheet license endpoint for The Gold Reaper v4.6.
 *
 * Bind this script to the spreadsheet that contains a "Licenses" tab and
 * deploy it as a Web app (execute as the owner, access: Anyone).
 *
 * Required columns: Account, Active
 * Optional columns: ExpiryUTC, Name, Server, Product
 */
const LICENSE_SHEET_NAME = 'Licenses';

function doGet(e) {
  try {
    const params = (e && e.parameter) || {};
    const account = clean_(params.account);
    const server = clean_(params.server);
    const product = clean_(params.product);

    const expectedKey = PropertiesService.getScriptProperties()
      .getProperty('LICENSE_API_KEY') || '';
    if (expectedKey && clean_(params.key) !== expectedKey) {
      return text_('DENIED|invalid_key');
    }
    if (!/^\d+$/.test(account)) {
      return text_('DENIED|invalid_account');
    }

    const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
    const sheet = spreadsheet.getSheetByName(LICENSE_SHEET_NAME);
    if (!sheet) {
      return text_('ERROR|missing_licenses_sheet');
    }

    const rows = sheet.getDataRange().getValues();
    if (rows.length < 2) {
      return text_('DENIED|account_not_found');
    }

    const columns = mapColumns_(rows[0]);
    if (columns.account < 0 || columns.active < 0) {
      return text_('ERROR|missing_account_or_active_column');
    }

    let accountSeen = false;
    for (let i = 1; i < rows.length; i += 1) {
      const row = rows[i];
      if (clean_(row[columns.account]) !== account) continue;
      accountSeen = true;

      if (!scopeMatches_(cell_(row, columns.server), server)) continue;
      if (!scopeMatches_(cell_(row, columns.product), product)) continue;

      if (!isActive_(cell_(row, columns.active))) {
        return text_('DENIED|license_inactive');
      }

      const expiry = expiryUnix_(cell_(row, columns.expiry));
      if (expiry === null) {
        return text_('ERROR|invalid_expiry');
      }
      if (expiry > 0 && Math.floor(Date.now() / 1000) >= expiry) {
        return text_('DENIED|license_expired');
      }

      const customer = safeField_(cell_(row, columns.name));
      return text_(`OK|${expiry}|${customer}`);
    }

    return text_(accountSeen
      ? 'DENIED|server_or_product_not_allowed'
      : 'DENIED|account_not_found');
  } catch (error) {
    console.error(error);
    return text_('ERROR|server_error');
  }
}

function mapColumns_(headerRow) {
  const result = {
    account: -1,
    active: -1,
    expiry: -1,
    name: -1,
    server: -1,
    product: -1,
  };

  headerRow.forEach((value, index) => {
    const header = normalizeHeader_(value);
    if (['account', 'accountlogin', 'login', 'mt5account'].includes(header)) {
      result.account = index;
    } else if (['active', 'status', 'enabled'].includes(header)) {
      result.active = index;
    } else if (['expiryutc', 'expiresutc', 'expiry', 'expiration', 'expire'].includes(header)) {
      result.expiry = index;
    } else if (['name', 'customer', 'client'].includes(header)) {
      result.name = index;
    } else if (['server', 'brokerserver'].includes(header)) {
      result.server = index;
    } else if (['product', 'ea'].includes(header)) {
      result.product = index;
    }
  });
  return result;
}

function normalizeHeader_(value) {
  return clean_(value).toLowerCase().replace(/[\s_-]/g, '');
}

function clean_(value) {
  return value === null || value === undefined ? '' : String(value).trim();
}

function cell_(row, index) {
  return index >= 0 && index < row.length ? row[index] : '';
}

function scopeMatches_(configured, actual) {
  const expected = clean_(configured).toUpperCase();
  return !expected || expected === '*' || expected === clean_(actual).toUpperCase();
}

function isActive_(value) {
  return ['ACTIVE', 'ENABLED', 'TRUE', 'YES', '1', 'OK']
    .includes(clean_(value).toUpperCase());
}

function expiryUnix_(value) {
  if (value === '' || value === null || value === undefined) return 0;
  if (value instanceof Date) {
    const milliseconds = value.getTime();
    return Number.isNaN(milliseconds) ? null : Math.floor(milliseconds / 1000);
  }

  const text = clean_(value);
  if (!text || ['0', 'NEVER', 'PERMANENT', 'UNLIMITED'].includes(text.toUpperCase())) {
    return 0;
  }
  if (/^\d+$/.test(text)) {
    const unix = Number(text);
    return Number.isSafeInteger(unix) && unix > 1000000000 ? unix : null;
  }

  const milliseconds = Date.parse(text);
  return Number.isNaN(milliseconds) ? null : Math.floor(milliseconds / 1000);
}

function safeField_(value) {
  return clean_(value).replace(/[|\r\n]/g, ' ');
}

function text_(body) {
  return ContentService.createTextOutput(body)
    .setMimeType(ContentService.MimeType.TEXT);
}
