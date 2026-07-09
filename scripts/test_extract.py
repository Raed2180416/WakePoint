import requests
from bs4 import BeautifulSoup
import re
import sys
import time

url = "https://yometro.com/shaheed-sthal-metro-station-110001"

def try_requests():
    print("Trying requests...")
    try:
        response = requests.get(url)
        response.raise_for_status()
        html = response.text
        print(f"HTML length: {len(html)}")
        
        soup = BeautifulSoup(html, 'html.parser')
        
        # Look for iframes
        iframes = soup.find_all('iframe')
        print(f"Found {len(iframes)} iframes.")
        for iframe in iframes:
            src = iframe.get('src')
            print(f"Iframe src: {src}")
            
        # Look for possible map containers
        map_divs = soup.find_all('div', id=re.compile(r'map'))
        print(f"Found {len(map_divs)} divs with 'map' in id.")
        
        if not iframes:
             # Check for raw string "google.com/maps"
             if "google.com/maps" in html:
                 print("Found 'google.com/maps' string in HTML, but no iframe element found by BS4.")
                 # Print context
                 idx = html.find("google.com/maps")
                 start = max(0, idx - 200)
                 end = min(len(html), idx + 200)
                 print(f"Context: {html[start:end]}")
             else:
                 print("'google.com/maps' not found in HTML.")
                 
    except Exception as e:
        print(f"Requests error: {e}")

def try_selenium():
    print("Trying selenium...")
    try:
        from selenium import webdriver
        from selenium.webdriver.chrome.options import Options
        from selenium.webdriver.common.by import By
        from webdriver_manager.chrome import ChromeDriverManager
        from selenium.webdriver.chrome.service import Service

        chrome_options = Options()
        chrome_options.add_argument("--headless")
        chrome_options.add_argument("--no-sandbox")
        chrome_options.add_argument("--disable-dev-shm-usage")

        # service = Service(ChromeDriverManager().install()) # Use if needed, but selenium 4 might handle it
        # Try default driver first
        try:
            driver = webdriver.Chrome(options=chrome_options)
        except:
            print("Default driver failed, trying Service + DriverManager")
            service = Service(ChromeDriverManager().install())
            driver = webdriver.Chrome(service=service, options=chrome_options)

        driver.get(url)
        time.sleep(5) # Wait for load

        iframes = driver.find_elements(By.TAG_NAME, "iframe")
        print(f"Selenium found {len(iframes)} iframes.")
        for iframe in iframes:
            src = iframe.get_attribute('src')
            print(f"Selenium Iframe src: {src}")

        # Try to find marker in map
        # If there is a google map iframe, we can't switch to it easily if cross-origin, 
        # but the src might have the info.
        
        driver.quit()
    except Exception as e:
        print(f"Selenium error: {e}")


    with open("scripts/extract_log.txt", "w", encoding="utf-8") as backend_log:
        def log(msg):
            print(msg)
            backend_log.write(msg + "\n")
            backend_log.flush()

        # Update all print calls to log calls inside the functions
        # This is a bit tedious with replace so I'll just rewrite the whole file content in next step or use write_to_file again.
        pass

if __name__ == "__main__":
    with open("d:/WakePoint/scripts/extract_log.txt", "w", encoding="utf-8") as f:
        sys.stdout = f
        try_requests()
        try_selenium()

