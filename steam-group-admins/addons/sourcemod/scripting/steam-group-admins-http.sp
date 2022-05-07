#pragma semicolon 1

#pragma dynamic 32767 //Increase memory limit to avoid crashes, according to cURL example plugin source

#include <sourcemod>
#include <cURL>

#define PLUGIN_VERSION "0.9.9b"

new GroupId:current_admin_group_id;
new current_steam_group_id;

new String:cache_dir_path[PLATFORM_MAX_PATH];
new String:cache_path[PLATFORM_MAX_PATH];
new Handle:cache_file = INVALID_HANDLE;
#define CURL_DATA_TAIL_SIZE 11 //11 is length of "<steamID64" including null
new String:last_curl_data_tail[CURL_DATA_TAIL_SIZE];
new bool:curl_data_match_found;

public Plugin:myinfo = {
  name = "Steam Group Admins (HTTP Prefetch)",
  author = "Mister_Magotchi",
  description = "Reads all players from Steam Community group XML member lists (via HTTP) and adds them to the admin cache.",
  version = PLUGIN_VERSION,
  url = "http://forums.alliedmods.net/showthread.php?t=145767"
};

public OnPluginStart () {
  CreateConVar(
    "sm_steam_group_admins_http_ver",
    PLUGIN_VERSION,
    "Steam Group Admins (HTTP Prefetch) Version",
    FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD
  );
  BuildPath(Path_SM, cache_dir_path, sizeof(cache_dir_path), "data/steam-group-admins-http");
  if (OpenDirectory(cache_dir_path) == INVALID_HANDLE) {
    if (!CreateDirectory(cache_dir_path, 511)) {
      LogError("Error accessing or creating cache directory: %s", cache_dir_path);
    }
  }
}

public OnRebuildAdminCache (AdminCachePart:part) {
  if (AdminCachePart:part == AdminCache_Groups || AdminCachePart:part == AdminCache_Admins) {
    new Handle:kv = CreateKeyValues("steam_groups");
    decl String:config_path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, config_path, sizeof(config_path), "configs/steam-group-admins-http.txt");
    FileToKeyValues(kv, config_path);
    if (KvGotoFirstSubKey(kv)) {
      if (AdminCachePart:part == AdminCache_Groups) {
        decl String:admin_group_name[128];
        do {
          KvGetString(kv, "admin_group_name", admin_group_name, sizeof(admin_group_name));
          new GroupId:admin_group_id;
          decl String:flags[32];
          KvGetString(kv, "flags", flags, sizeof(flags));
          new immunity;
          immunity = KvGetNum(kv, "immunity");
          if ((admin_group_id = FindAdmGroup(admin_group_name)) == INVALID_GROUP_ID) {
            admin_group_id = CreateAdmGroup(admin_group_name);
          }
          new flags_count = strlen(flags);
          for (new i = 0; i < flags_count; i++) {
            decl AdminFlag:flag;
            if (!FindFlagByChar(flags[i], flag)) {
              continue;
            }
            SetAdmGroupAddFlag(admin_group_id, flag, true);
          }
          if (immunity) {
            SetAdmGroupImmunityLevel(admin_group_id, immunity);
          }
        } while (KvGotoNextKey(kv));
        CloseHandle(kv);
      }
      else {
        process_next_group_list(kv);
      }
    }
  }
}

process_next_group_list (Handle:kv) {
  decl String:group_id[10];
  KvGetSectionName(kv, group_id, sizeof(group_id));
  current_steam_group_id = StringToInt(group_id);
  decl String:admin_group_name[128];
  KvGetString(kv, "admin_group_name", admin_group_name, sizeof(admin_group_name));
  current_admin_group_id = FindAdmGroup(admin_group_name);
  decl String:url[71];
  Format(url, sizeof(url), "http://steamcommunity.com/gid/%i/memberslistxml/?xml=1", current_steam_group_id);
  new Handle:curl = curl_easy_init();
  if (curl != INVALID_HANDLE) {
    curl_easy_setopt_function(curl, CURLOPT_WRITEFUNCTION, on_curl_got_data);
    curl_easy_setopt_int(curl, CURLOPT_FAILONERROR, true);
    curl_easy_setopt_string(curl, CURLOPT_URL, url);
    curl_data_match_found = false;
    last_curl_data_tail = "";
    Format(cache_path, sizeof(cache_path), "%s/%i.xml", cache_dir_path, current_steam_group_id);
    curl_easy_perform_thread(curl, on_curl_finished, kv);
  }
}

public on_curl_got_data (Handle:hndl, const String:buffer[], const bytes, const nmemb) {
  if (!curl_data_match_found) {
    decl String:data[nmemb + CURL_DATA_TAIL_SIZE];
    strcopy(data, CURL_DATA_TAIL_SIZE, last_curl_data_tail);
    StrCat(data, nmemb + CURL_DATA_TAIL_SIZE, buffer);
    new match_position;
    match_position = StrContains(data, "<steamID64>");
    if (match_position != -1) {
      curl_data_match_found = true;
      cache_file = OpenFile(cache_path, "w");
      if (cache_file == INVALID_HANDLE) {
        LogMessage("Error opening cache file for writing: %i.xml", current_steam_group_id);
        return 0; //tell cURL 0 bytes were handled, which should trigger CURLE_WRITE_ERROR
      }
      WriteFileString(cache_file, data[match_position], false);
    }
    else {
      strcopy(last_curl_data_tail, CURL_DATA_TAIL_SIZE, buffer[nmemb - (CURL_DATA_TAIL_SIZE - 1)]);
    }
  }
  else {
    WriteFileString(cache_file, buffer, false);
  }
  return bytes * nmemb;
}

public on_curl_finished (Handle:curl, CURLcode:code, any:kv) {
  if (curl_data_match_found) {
    CloseHandle(cache_file);
  }
  else if (code != CURLE_OK || !curl_data_match_found) {
    LogMessage("Couldn't fetch fresh XML data from Steam API server for Steam group ID: %i. Using old cached data, if available.", current_steam_group_id);
  }
  CloseHandle(curl);
  
  cache_file = OpenFile(cache_path, "r");
  if (cache_file != INVALID_HANDLE) {
    decl String:line[50]; //arbitary, but leaves room for minor format changes
    new id_start_pos;
    decl String:steam_id_64[18], String:steam_id[17];
    while (ReadFileLine(cache_file, line, sizeof(line))) {
      if ((id_start_pos = StrContains(line, "<steamID64>")) != -1) {
        strcopy(steam_id_64, sizeof(steam_id_64), line[id_start_pos + 11]);
        steam_id_64_to_steam_id(steam_id_64, steam_id);
        new AdminId:admin;
        if ((admin = FindAdminByIdentity(AUTHMETHOD_STEAM, steam_id)) == INVALID_ADMIN_ID) {
          admin = CreateAdmin(steam_id);
          BindAdminIdentity(admin, AUTHMETHOD_STEAM, steam_id);
        }
        AdminInheritGroup(admin, current_admin_group_id);
      }
    }
    CloseHandle(cache_file);
  }
  else {
    LogError("Error reading XML data from local cached file for Steam group ID: %i.", current_steam_group_id);
  }

  if (KvGotoNextKey(kv)) {
    process_next_group_list(kv);
  }
  else {
    CloseHandle(kv);
  }
}

//The highest possible Steam ID is [U:1:4294967296] (76561202255233023 or 0x01100001FFFFFFFF),
steam_id_64_to_steam_id (String:steam_id_64[18], String:steam_id[17]) {
  //convert SteamID64 to array of integers
  decl steam_id_64_work[17];
  decl String:digit[2];
  for (new c = 0; c < 17; c++) {
    strcopy(digit, 2, steam_id_64[c]);
    steam_id_64_work[c] = StringToInt(digit);
  }

  //subtract individual SteamID64 identifier (0x0110000100000000)
  new indiv_ident[] = {7, 6, 5, 6, 1, 1, 9, 7, 9, 6, 0, 2, 6, 5, 7, 2, 8};
  new carry = 0;
  for (new c = 16; c >= 0; c--) {
    if (steam_id_64_work[c] < indiv_ident[c] + carry) {
      steam_id_64_work[c] = steam_id_64_work[c] - indiv_ident[c] - carry + 10;
      carry = 1;
    }
    else {
      steam_id_64_work[c] = steam_id_64_work[c] - indiv_ident[c] - carry;
      carry = 0;
    }
  }

  //copy result back to Steam ID format
  new String:steam_id_64_work_string[17];
  new zeros_done = false;
  for (new c = 0; c < 17; c++) {
    if (zeros_done || steam_id_64_work[c] != 0) {
      zeros_done = true;
      IntToString(steam_id_64_work[c], digit, 2);
      StrCat(steam_id_64_work_string, 17, digit);
    }
  }
  Format(steam_id, sizeof(steam_id), "[U:1:%s]", steam_id_64_work_string);
}
