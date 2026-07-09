import requests
from bs4 import BeautifulSoup
import re
import json
import time
import sys
import os
from concurrent.futures import ThreadPoolExecutor, as_completed

# Configuration
CITIES = {
    "delhi": "https://yometro.com/delhi-metro-11",
    "mumbai": "https://yometro.com/mumbai-metro-14",
    "chennai": "https://yometro.com/chennai-metro-17",
    "kolkata": "https://yometro.com/kolkata-metro-19",
    "navimumbai": "https://yometro.com/navi-mumbai-metro-36"
}

HEADERS = {
    # Randomized user agent could be better but sticking to simple one
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
    "Referer": "https://yometro.com/"
}

OUTPUT_FILE = "d:/WakePoint/scripts/scraped_metro_data.json"

def get_soup(url):
    try:
        # time.sleep(0.5) # Reduced sleep
        response = requests.get(url, headers=HEADERS, timeout=10)
        response.raise_for_status()
        return BeautifulSoup(response.text, 'html.parser')
    except Exception as e:
        print(f"Error fetching {url}: {e}")
        return None

def extract_coords_from_embed(embed_url):
    try:
        response = requests.get(embed_url, headers=HEADERS, timeout=10)
        html = response.text
        matches = re.findall(r'\[\s*(-?\d+\.\d+)\s*,\s*(-?\d+\.\d+)\s*\]', html)
        
        candidates = []
        for m in matches:
            lat, lng = float(m[0]), float(m[1])
            if 8.0 <= lat <= 36.0 and 68.0 <= lng <= 98.0:
                candidates.append((lat, lng))
        
        if candidates:
            return candidates[0]
            
    except Exception as e:
        print(f"Error parsing embed {embed_url}: {e}")
    return None

def get_station_coords(station_url):
    soup = get_soup(station_url)
    if not soup:
        return None

    iframe_src = None
    amp_iframe = soup.find('amp-iframe', attrs={'src': re.compile(r'google\.com/maps')})
    if amp_iframe:
        iframe_src = amp_iframe['src']
    else:
        iframe = soup.find('iframe', attrs={'src': re.compile(r'google\.com/maps')})
        if iframe:
            iframe_src = iframe['src']
    
    if iframe_src:
        return extract_coords_from_embed(iframe_src)
    
    return None

def process_station(task_data):
    st_name, st_href, city_name, line_name, line_color = task_data
    # print(f"Scraping {st_name}...")
    coords = get_station_coords(st_href)
    if coords:
        print(f"✓ {st_name} ({line_name}): {coords}")
        return {
            "city": city_name,
            "name": st_name,
            "line": line_name,
            "lineColor": line_color,
            "lat": coords[0],
            "lng": coords[1],
            "url": st_href
        }
    else:
        print(f"✗ Failed {st_name}")
        return None

def scrape_city(city_name, city_url):
    print(f"Searching lines in {city_name}...")
    soup = get_soup(city_url)
    if not soup:
        return []

    potential_lines = []
    links = soup.find_all('a', href=True)
    for link in links:
        text = link.get_text().strip()
        href = link['href']
        if "Line" in text and "yometro.com" in href:
             potential_lines.append((text, href))

    unique_lines = {}
    for text, href in potential_lines:
        if href not in unique_lines:
            unique_lines[href] = text
    
    tasks = []
    
    for href, text in unique_lines.items():
        if "Branch" in text or "Main" in text: 
            pass
        
        # Determine Color
        line_color = "0xFF000000"
        lower_text = text.lower()
        if "red" in lower_text: line_color = "0xFFC0282C"
        elif "yellow" in lower_text: line_color = "0xFFF6D71A"
        elif "blue" in lower_text: line_color = "0xFF3B76C0"
        elif "green" in lower_text: line_color = "0xFF54AB55"
        elif "violet" in lower_text: line_color = "0xFF8115FF"
        elif "pink" in lower_text: line_color = "0xFFED91C9"
        elif "magenta" in lower_text: line_color = "0xFFF300F3"
        elif "grey" in lower_text or "gray" in lower_text: line_color = "0xFF808080"
        elif "orange" in lower_text: line_color = "0xFFF46808"
        elif "aqua" in lower_text: line_color = "0xFF00FFFF"
        elif "purple" in lower_text: line_color = "0xFFA020F0"
        
        line_soup = get_soup(href)
        if not line_soup:
            continue
            
        l_links = line_soup.find_all('a', href=True)
        station_links = []
        for l in l_links:
            st_text = l.get_text().strip()
            st_href = l['href']
            
            if "Line" in st_text: continue
            if "Metro" in st_text and "Network" in st_text: continue
            if "Map" in st_text: continue
            if "yometro.com" not in st_href: continue
            if "station" not in st_href and "metro" not in st_href: continue 
            
            if "metro-station" in st_href:
                station_links.append((st_text, st_href))
        
        unique_stations = {}
        for st_text, st_href in station_links:
            if st_href not in unique_stations:
                unique_stations[st_href] = st_text
        
        for st_href, st_name in unique_stations.items():
            tasks.append((st_name, st_href, city_name, text, line_color))
            
    print(f"  Found {len(tasks)} stations to scrape for {city_name}.")
    
    results = []
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(process_station, t): t for t in tasks}
        for future in as_completed(futures):
            res = future.result()
            if res:
                results.append(res)
                
    return results

def main():
    all_data = []
    for city, url in CITIES.items():
        city_data = scrape_city(city, url)
        all_data.extend(city_data)
        
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        json.dump(all_data, f, indent=2)
    
    print(f"Scraping complete. Saved to {OUTPUT_FILE}")

if __name__ == "__main__":
    main()
