import 'dart:io';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;

const _kClientId = 'PASTE_HERE';
const _kClientSecret = 'PASTE_HERE';
const _kRedirectUrl = 'http://localhost:6060/callback';

typedef Json = Map<String, dynamic>;

void main(List<String> arguments) async {
  // Obtain an authorization token from the user
  final token = await _authorize();

  // Use the authorization token to fetch the user's library
  final library = await _fetchLibrary(token);

  // Compile a list of all albums in the library
  final albums = _compileAlbums(library);

  final albumsNotInLibrary =
      await _filterOutAlbumsAlreadyInLibrary(token, albums);

  print('Albums not in library: ${albumsNotInLibrary.length}\n');

  // Prompt the user to save each album to their library
  await _promptToSaveAlbums(token, albumsNotInLibrary);

  print('All done!');
}

Future<String> _authorize() async {
  // Set up OAuth2 client credentials
  final scopes = [
    'user-library-read',
    'user-library-modify',
  ];
  final authorizationEndpoint =
      Uri.parse('https://accounts.spotify.com/authorize');
  final tokenEndpoint = Uri.parse('https://accounts.spotify.com/api/token');
  final credentials = base64.encode(utf8.encode('$_kClientId:$_kClientSecret'));

  // Obtain an authorization code from the user
  final authorizationUrl = authorizationEndpoint.replace(queryParameters: {
    'client_id': _kClientId,
    'response_type': 'code',
    'redirect_uri': _kRedirectUrl,
    'scope': scopes.join(' '),
  });
  print('Please go to the following URL and grant access:');
  print(authorizationUrl);
  print('');

  // Wait for the user to grant authorization and retrieve the authorization code
  print('Enter the authorization code:');
  final code = stdin.readLineSync();

  // Exchange the authorization code for an access token
  final response = await http.post(
    tokenEndpoint,
    headers: {
      'Authorization': 'Basic $credentials',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': _kRedirectUrl,
    },
  );

  if (response.statusCode != 200) {
    print('Failed to obtain access token: ${response.reasonPhrase}');
    exit(1);
  }

  final token = json.decode(response.body)?['access_token'];

  if (token == null) {
    print('Failed to obtain access token: ${response.body}');
    exit(1);
  }

  print('Authorization done.\n');

  return token;
}

Future<List<Json>> _fetchLibrary(String token) async {
  print('Fetching library...');

  // Fetch the user's library
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };
  final libraryEndpoint = 'https://api.spotify.com/v1/me/tracks?limit=50';
  var libraryResponse =
      await http.get(Uri.parse(libraryEndpoint), headers: headers);
  if (libraryResponse.statusCode != 200) {
    print('Failed to fetch library: ${libraryResponse.reasonPhrase}');
    for (var i = 0; i < 2; i++) {
      print('Retrying...');
      libraryResponse =
          await http.get(Uri.parse(libraryEndpoint), headers: headers);
      if (libraryResponse.statusCode == 200) {
        break;
      }
      sleep(Duration(seconds: 5));
    }
    if (libraryResponse.statusCode != 200) {
      print('Failed to fetch library after retrying');
      exit(1);
    }
  }
  var libraryData = json.decode(libraryResponse.body);
  var library = List<Json>.from(libraryData['items']);

  // Fetch additional pages of the library
  while (libraryData['next'] != null) {
    var nextUrl = libraryData['next'] as String;
    var nextPageResponse = await http.get(Uri.parse(nextUrl), headers: headers);
    if (nextPageResponse.statusCode != 200) {
      print(
          'Failed to fetch next page of library: ${nextPageResponse.reasonPhrase}');
      for (var i = 0; i < 2; i++) {
        print('Retrying...');
        nextPageResponse = await http.get(Uri.parse(nextUrl), headers: headers);
        if (nextPageResponse.statusCode == 200) {
          break;
        }
        sleep(Duration(seconds: 5));
      }
      if (nextPageResponse.statusCode != 200) {
        print('Failed to fetch next page of library after retrying');
        exit(1);
      }
    }
    var nextPageData = json.decode(nextPageResponse.body);
    library.addAll(List<Json>.from(nextPageData['items']));
    libraryData = nextPageData;
  }

  return library;
}

List<Json> _compileAlbums(List<Json> library) {
  // Compile a list of all albums in the library
  final albums = <Json>[];
  for (var item in library) {
    final album = item['track']['album'];
    if (albums.indexWhere((a) => a['id'] == album['id']) == -1) {
      albums.add(album);
    }
  }
  return albums;
}

Future<List<Json>> _filterOutAlbumsAlreadyInLibrary(
    String accessToken, List<Json> albums) async {
  final ids = albums.map<String>((it) => it['id']).toList();
  final chunks = ids.slices(20);
  final idsOfAlbumsInLibrary = <String>[];
  for (var chunk in chunks) {
    final url =
        'https://api.spotify.com/v1/me/albums/contains?ids=${chunk.join(',')}';
    final response = await http.get(
      Uri.parse(url),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $accessToken'},
    );
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as List<dynamic>;
      idsOfAlbumsInLibrary
          .addAll(chunk.where((id) => decoded[chunk.indexOf(id)]).toList());
    } else {
      print('Failed to check albums in library: ${response.reasonPhrase}');
      exit(1);
    }
  }
  return albums
      .where((it) => !idsOfAlbumsInLibrary.contains(it['id']))
      .toList();
}

Future<void> _promptToSaveAlbums(String token, List<Json> albums) async {
  // Prompt the user to save each album to their library
  for (var album in albums) {
    final artistName = album['artists'][0]['name'];
    final albumName = album['name'];
    final albumID = album['id'];
    final image = album['images'][0]['url'];
    final link = album['external_urls']['spotify'];
    print('$artistName - $albumName');
    print('Image: $image');
    print('Link: $link');
    print('Would you like to save this album to your library? (Y/n)');
    var answer = stdin.readLineSync() ?? '';
    if (answer.toLowerCase() != 'n') {
      answer = 'y';
    }
    if (answer.toLowerCase() == 'y') {
      final saveEndpoint = 'https://api.spotify.com/v1/me/albums?ids=$albumID';
      final headers = {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };
      final response = await http.put(
        Uri.parse(saveEndpoint),
        headers: headers,
      );
      if (response.statusCode == 200) {
        print('Saved.');
      } else {
        print('Failed to save album: ${response.reasonPhrase}');
      }
    } else {
      print('Skipping...');
    }
  }
}
