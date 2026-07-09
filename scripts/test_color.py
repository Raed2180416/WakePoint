import requests
from bs4 import BeautifulSoup
import re

url = "https://yometro.com/delhi-metro-red-line-1101"

try:
    response = requests.get(url)
    html = response.text
    soup = BeautifulSoup(html, 'html.parser')
    
    # Text "Red Line"
    # Find elements containing "Red Line"
    # The header might have a color border or text color
    
    # Look for style attributes
    tags = soup.find_all(lambda tag: tag.has_attr('style') and '#' in tag['style'])
    print(f"Found {len(tags)} tags with color-like styles.")
    for tag in tags[:10]:
        print(f"Tag: {tag.name}, Style: {tag['style']}, Text: {tag.get_text()[:50]}")
        
    # Specifically look for line list items
    # They looked like [◙ Red Line] in the markdown
    # Markdown ◙ is probably a circle or icon element
    
    links = soup.find_all('a')
    for link in links:
        if "Red Line" in link.get_text():
             print(f"Link: {link.get_text()}, Style: {link.get('style')}, Class: {link.get('class')}")
             # Check children
             for child in link.children:
                 if child.name:
                     print(f"  Child: {child.name}, Style: {child.get('style')}")

except Exception as e:
    print(e)
